<?php

namespace App\Concerns;

use Carbon\CarbonImmutable;
use Illuminate\Support\Facades\Log;
use Symfony\Component\HttpFoundation\ResponseHeaderBag;
use Symfony\Component\HttpFoundation\StreamedResponse;

/**
 * CSV serialization for the report exports — and nothing else.
 *
 * SCOPE. Response construction, row writing, the BOM, text sanitisation,
 * numeric/date formatting and the filename. There is deliberately NO
 * fiscal-year logic here: the four-digit month headings live in
 * ResolvesFiscalYear beside fiscalMonthLabels(), because a CSV writer that
 * knows the fiscal calendar is two concerns in one file.
 *
 * Everything except streamCsv() is container-free, so tests/Unit/StreamsCsvTest
 * can `use StreamsCsv;` on a plain PHPUnit TestCase — the same DB-free seam
 * DerivesAllocationLines and DerivesRequisitionDetail exist for. That matters
 * more here than anywhere else in the app: the feature tests SKIP without SQL
 * Server, so this suite is the only guaranteed coverage of the
 * formula-injection guard.
 *
 * FORMAT. UTF-8 with BOM (Excel on Windows is the destination), RFC 4180
 * quoting, CRLF terminators, and NO backslash escaping — see csvPut().
 */
trait StreamsCsv
{
    /** Excel will not detect UTF-8 in a CSV without this. */
    private const CSV_BOM = "\xEF\xBB\xBF";

    /** Leading characters a spreadsheet treats as the start of a formula. */
    private const CSV_FORMULA_LEADERS = ['=', '+', '-', '@'];

    // =========================================================================
    // Response
    // =========================================================================

    /**
     * Stream a CSV download.
     *
     * $rows is a closure returning an iterable of row arrays, so the caller can
     * hand over a generator and nothing is buffered twice.
     *
     * MID-STREAM FAILURE IS UNRECOVERABLE. Once the BOM is written the headers
     * are committed and no exception can be turned into a redirect, so every
     * predictable failure (no access, stale filter, empty result, source down)
     * is checked by the caller BEFORE this is reached. What can still fail here
     * is row formatting and the output write itself; those are logged loudly
     * and leave a truncated file, which is the best available outcome.
     *
     * @param  array<int,string>  $headings
     */
    protected function streamCsv(string $filename, array $headings, \Closure $rows, array $context = []): StreamedResponse
    {
        $response = new StreamedResponse(function () use ($headings, $rows, $filename, $context) {
            $handle = fopen('php://output', 'wb');

            echo self::CSV_BOM;
            $this->csvPut($handle, $headings);

            $written = 0;

            try {
                foreach ($rows() as $row) {
                    $this->csvPut($handle, $row);
                    $written++;
                }
            } catch (\Throwable $e) {
                Log::error('CSV export stream failed.', $context + [
                    'file' => $filename,
                    'rows_written' => $written,
                    'exception' => $e->getMessage(),
                ]);

                fflush($handle);

                return;
            }

            fflush($handle);

            Log::info('CSV export completed.', $context + [
                'file' => $filename,
                'rows' => $written,
            ]);
        });

        $response->headers->set('Content-Type', 'text/csv; charset=UTF-8');
        $response->headers->set('Content-Disposition', $response->headers->makeDisposition(
            ResponseHeaderBag::DISPOSITION_ATTACHMENT,
            $filename,
        ));
        $response->headers->set('Cache-Control', 'private, no-store');
        $response->headers->set('X-Content-Type-Options', 'nosniff');

        return $response;
    }

    /**
     * Write one RFC 4180 record.
     *
     * The empty $escape argument is load-bearing: PHP's default backslash
     * escaping is proprietary and not RFC 4180, and it mangles any cell holding
     * a backslash. With it empty a quote is doubled and a backslash is emitted
     * literally, which is what every spreadsheet and CSV parser expects.
     *
     * $eol has been available on fputcsv since well before PHP 8.4, so there is
     * no need to build the line by hand to get CRLF.
     *
     * @param  resource  $handle
     * @param  array<int,string>  $cells
     */
    protected function csvPut($handle, array $cells): void
    {
        fputcsv($handle, $cells, ',', '"', '', "\r\n");
    }

    // =========================================================================
    // Cell formatting
    // =========================================================================

    /**
     * A TEXT cell, guarded against spreadsheet formula injection.
     *
     * TWO INDEPENDENT CLAUSES, and collapsing them into one is a real bug that
     * an earlier draft of the plan shipped:
     *
     *   1. the RAW first byte is TAB or CR; or
     *   2. after skipping leading whitespace and control characters, the first
     *      character is = + - or @.
     *
     * "The first non-control character is =, +, -, @, TAB or CR" is
     * unsatisfiable — TAB and CR *are* control characters, so once they are
     * skipped you can never land on one. Clause 1 catches a leading TAB/CR in
     * its own right; clause 2 catches " =1+1" and "\t=1+1", which spreadsheets
     * parse as formulas and a first-character-only check misses.
     *
     * The value is never truncated or rewritten, only prefixed — an apostrophe
     * is what Excel strips on display while the raw file keeps the original
     * bytes after it.
     */
    protected function csvText(mixed $value): string
    {
        if ($value === null) {
            return '';
        }

        $raw = (string) $value;

        if ($raw === '') {
            return '';
        }

        if ($raw[0] === "\t" || $raw[0] === "\r") {
            return "'".$raw;
        }

        // Byte-safe (no /u): a malformed UTF-8 cell must not make the guard throw.
        $trimmed = (string) preg_replace('/^[\x00-\x20]+/', '', $raw);

        if ($trimmed !== '' && in_array($trimmed[0], self::CSV_FORMULA_LEADERS, true)) {
            return "'".$raw;
        }

        return $raw;
    }

    /**
     * Money, as a raw decimal with no currency symbol or thousands separator so
     * a spreadsheet reads it as a number it can compute on.
     *
     * NEVER routed through csvText(): a genuine -1234.56 begins with a formula
     * leader, and prefixing it would turn every negative figure in the file
     * into text. The guard is about the cell's TYPE, not its first character.
     */
    protected function csvMoney(mixed $value): string
    {
        $number = (float) $value;

        // -0.0 formats as "-0.00", which reads as a negative zero balance.
        if ($number == 0.0) {
            $number = 0.0;
        }

        return number_format($number, 2, '.', '');
    }

    /**
     * A quantity at the source's decimal(19,4) precision, trailing zeros
     * trimmed so whole units read as "3" rather than "3.0000".
     */
    protected function csvQuantity(mixed $value): string
    {
        $number = (float) $value;

        if ($number == 0.0) {
            $number = 0.0;
        }

        $formatted = number_format($number, 4, '.', '');

        if (str_contains($formatted, '.')) {
            $formatted = rtrim(rtrim($formatted, '0'), '.');
        }

        return $formatted === '' ? '0' : $formatted;
    }

    /**
     * An ISO date.
     *
     * null or blank is a genuinely absent date and becomes an empty cell. A
     * parseable value is emitted directly — an ISO date can never trigger the
     * formula guard, so it does not need it.
     *
     * AN UNPARSEABLE NON-NULL VALUE FALLS BACK THROUGH csvText(). It is logged
     * rather than silently erased, and it is guarded rather than written raw:
     * the moment a date fails to parse it is source-controlled text of unknown
     * shape, and emitting it unguarded would reopen the exact injection hole
     * csvText() exists to close. It must not throw either — see streamCsv().
     */
    protected function csvDate(mixed $value): string
    {
        if ($value === null || trim((string) $value) === '') {
            return '';
        }

        $raw = (string) $value;

        try {
            return CarbonImmutable::parse($raw)->format('Y-m-d');
        } catch (\Throwable $e) {
            $this->csvUnparseableDate($raw, $e);

            return $this->csvText($raw);
        }
    }

    /**
     * Reported separately so the unit suite can observe it without a container.
     */
    protected function csvUnparseableDate(string $raw, \Throwable $e): void
    {
        Log::warning('CSV export encountered an unparseable date.', [
            'exception' => $e->getMessage(),
        ]);
    }

    // =========================================================================
    // Filename
    // =========================================================================

    /**
     * "variance-fy2026-20260829-143501.csv".
     *
     * Deliberately carries NO username, department or filter value: a filename
     * is visible in a downloads list, a shared folder and a support ticket, and
     * none of those are places to leak who a report belongs to.
     *
     * CarbonImmutable::now() rather than now(), so the helper works — and can be
     * frozen with setTestNow() — outside the container.
     */
    protected function csvFilename(string $slug, ?int $fiscalYear): string
    {
        $parts = [$slug];

        if ($fiscalYear !== null) {
            $parts[] = 'fy'.$fiscalYear;
        }

        $parts[] = CarbonImmutable::now()->format('Ymd-His');

        return implode('-', $parts).'.csv';
    }
}
