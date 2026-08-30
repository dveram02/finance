<?php

namespace Tests\Unit;

use App\Concerns\ResolvesFiscalYear;
use App\Concerns\StreamsCsv;
use Carbon\CarbonImmutable;
use PHPUnit\Framework\TestCase;

/**
 * Offline regression net for the CSV writer.
 *
 * This suite exists for the same reason DerivesAllocationLinesTest does: every
 * export feature test SKIPS when SQL Server is unreachable, so without a
 * container-free seam the formula-injection guard would have NO coverage in CI
 * at all. It is the only place the security-relevant behaviour is pinned.
 *
 * The trait is used directly on a plain PHPUnit TestCase — no application, no
 * container — which is why csvFilename() uses CarbonImmutable::now() and
 * csvUnparseableDate() is a hook rather than a Log:: call inline.
 */
class StreamsCsvTest extends TestCase
{
    use ResolvesFiscalYear;
    use StreamsCsv;

    /** @var array<int,string> */
    private array $unparseableDates = [];

    protected function csvUnparseableDate(string $raw, \Throwable $e): void
    {
        $this->unparseableDates[] = $raw;
    }

    protected function tearDown(): void
    {
        CarbonImmutable::setTestNow();
        parent::tearDown();
    }

    /** Encode one record exactly as streamCsv() would. */
    private function encode(array $cells): string
    {
        $handle = fopen('php://temp', 'r+');
        $this->csvPut($handle, $cells);
        rewind($handle);
        $out = stream_get_contents($handle);
        fclose($handle);

        return $out;
    }

    // =========================================================================
    // The formula-injection guard — clause 1: a raw leading TAB or CR
    // =========================================================================

    public function test_a_leading_tab_or_carriage_return_is_guarded_on_its_own(): void
    {
        // Tested separately from clause 2, and deliberately with NO formula
        // character anywhere in the value: an earlier draft folded the two
        // clauses into one unsatisfiable rule ("the first non-control character
        // is =, +, -, @, TAB or CR"), which silently lost this case entirely.
        $this->assertSame("'\tplain text", $this->csvText("\tplain text"));
        $this->assertSame("'\rplain text", $this->csvText("\rplain text"));
    }

    // =========================================================================
    // The formula-injection guard — clause 2: a leader after whitespace/control
    // =========================================================================

    public static function formulaPayloads(): array
    {
        return [
            'equals' => ['=1+1'],
            'plus' => ['+1+1'],
            'at' => ['@SUM(1)'],
            'minus' => ['-SUM(A1:A2)'],
            'leading space' => [' =1+1'],
            'leading tab' => ["\t=1+1"],
            'leading cr' => ["\r=1+1"],
            'leading nul' => ["\x00=1+1"],
            'cmd payload' => ['=cmd|\'/c calc\'!A1'],
        ];
    }

    /** @dataProvider formulaPayloads */
    public function test_formula_like_text_is_apostrophe_prefixed(string $payload): void
    {
        $guarded = $this->csvText($payload);

        $this->assertSame("'".$payload, $guarded);
        // Prefixed, never rewritten — the original bytes survive after the quote.
        $this->assertStringEndsWith($payload, $guarded);
    }

    public function test_ordinary_text_is_untouched(): void
    {
        foreach (['Radiology', 'A-B-C', 'x = y', '', 'Ward 3 (North)'] as $value) {
            $this->assertSame($value, $this->csvText($value));
        }
    }

    public function test_null_becomes_an_empty_cell(): void
    {
        $this->assertSame('', $this->csvText(null));
    }

    public function test_the_guard_does_not_throw_on_malformed_utf8(): void
    {
        // The byte-safe regex (no /u) is what keeps this from blowing up
        // mid-stream, where an exception cannot become an error page.
        $this->assertSame("\xC3\x28", $this->csvText("\xC3\x28"));
    }

    // =========================================================================
    // Typing — the distinction the guard must not blur
    // =========================================================================

    public function test_negative_money_stays_numeric_and_is_not_prefixed(): void
    {
        $this->assertSame('-1234.56', $this->csvMoney(-1234.56));
        $this->assertSame('-1234.5600', $this->csvQuantity(-1234.56).'00');
    }

    public function test_a_text_identifier_that_looks_negative_is_still_guarded(): void
    {
        // Same characters, different cell type. The guard keys on the path the
        // value took, not on what it happens to look like.
        $this->assertSame("'-1234", $this->csvText('-1234'));
        $this->assertSame('-1234.00', $this->csvMoney('-1234'));
    }

    // =========================================================================
    // Numeric formatting
    // =========================================================================

    public function test_money_is_a_bare_two_decimal_string(): void
    {
        $this->assertSame('1234.56', $this->csvMoney(1234.56));
        $this->assertSame('0.00', $this->csvMoney(0));
        $this->assertSame('0.00', $this->csvMoney(null));
        // decimal:2 casts arrive as strings.
        $this->assertSame('1234.56', $this->csvMoney('1234.5600'));
        $this->assertStringNotContainsString(',', $this->csvMoney(1234567.89));
    }

    public function test_negative_zero_does_not_render_as_minus_zero(): void
    {
        $this->assertSame('0.00', $this->csvMoney(-0.0));
        $this->assertSame('0', $this->csvQuantity(-0.0));
    }

    public function test_quantity_keeps_four_decimals_and_trims_trailing_zeros(): void
    {
        $this->assertSame('3', $this->csvQuantity(3.0));
        $this->assertSame('3.5', $this->csvQuantity(3.5));
        $this->assertSame('3.0001', $this->csvQuantity(3.0001));
        $this->assertSame('0', $this->csvQuantity(0));
    }

    // =========================================================================
    // Dates
    // =========================================================================

    public function test_dates_are_iso_and_blanks_are_empty(): void
    {
        $this->assertSame('2026-08-29', $this->csvDate('2026-08-29'));
        $this->assertSame('2026-08-29', $this->csvDate('2026-08-29 00:00:00.000'));
        $this->assertSame('', $this->csvDate(null));
        $this->assertSame('', $this->csvDate('   '));
        $this->assertSame([], $this->unparseableDates);
    }

    public function test_an_unparseable_date_is_reported_and_never_silently_erased(): void
    {
        $this->assertSame('not a date', $this->csvDate('not a date'));
        $this->assertSame(['not a date'], $this->unparseableDates);
    }

    public function test_an_unparseable_date_falls_back_through_the_text_guard(): void
    {
        // The whole point of the fallback routing through csvText(). A value
        // that failed to parse is no longer a date, it is source-controlled
        // text — emitting it raw would reopen the injection hole the guard
        // exists to close. Asserting it here is what stops a future refactor
        // turning the date path back into an unguarded passthrough.
        $this->assertSame("'=cmd|'/c calc'!A1", $this->csvDate('=cmd|\'/c calc\'!A1'));
        $this->assertSame(['=cmd|\'/c calc\'!A1'], $this->unparseableDates);
    }

    // =========================================================================
    // Identifiers — must survive byte for byte (see export.md section 10.3)
    // =========================================================================

    public function test_leading_zero_identifiers_are_preserved_unprefixed(): void
    {
        $this->assertSame('00123', $this->csvText('00123'));
        // Unquoted, because nothing in it needs quoting — and crucially NOT
        // rewritten to 123. The file holds the true value; Excel's default open
        // is what strips the zeros, which is a viewer limitation, not ours.
        $this->assertSame("00123\r\n", $this->encode(['00123']));
    }

    public function test_identifiers_beyond_excel_numeric_precision_are_preserved(): void
    {
        // 18 significant digits: Excel would round this to 15 on open, but the
        // FILE must still hold the true value for every other consumer.
        $id = '123456789012345678';
        $this->assertSame($id, $this->csvText($id));
        $this->assertStringContainsString($id, $this->encode([$id]));
    }

    // =========================================================================
    // RFC 4180 encoding
    // =========================================================================

    public function test_records_are_crlf_terminated(): void
    {
        $this->assertSame("a,b\r\n", $this->encode(['a', 'b']));
    }

    public function test_special_characters_round_trip(): void
    {
        $cells = ['plain', 'has,comma', 'has"quote', "has\nnewline"];
        $line = $this->encode($cells);

        $this->assertSame($cells, str_getcsv(rtrim($line, "\r\n"), ',', '"', ''));
    }

    public function test_a_backslash_is_emitted_literally_not_escaped(): void
    {
        // PHP's DEFAULT escape character is a backslash, which is proprietary
        // and not RFC 4180 — it would corrupt any cell containing one. The
        // empty $escape argument in csvPut() is what prevents that.
        //
        // Tested inside a cell that MUST be quoted (it holds a comma), because
        // that is where the default escaping actually bites.
        $line = $this->encode(['back\\slash,here', 'x']);

        $this->assertSame('"back\\slash,here",x'."\r\n", $line);
        $this->assertStringNotContainsString('\\\\', $line);
        $this->assertSame(
            ['back\\slash,here', 'x'],
            str_getcsv(rtrim($line, "\r\n"), ',', '"', '')
        );
    }

    // =========================================================================
    // Filename
    // =========================================================================

    public function test_the_filename_is_slug_year_and_timestamp(): void
    {
        CarbonImmutable::setTestNow(CarbonImmutable::parse('2026-08-29 14:35:01'));

        $this->assertSame('variance-fy2026-20260829-143501.csv', $this->csvFilename('variance', 2026));
        $this->assertMatchesRegularExpression(
            '/^variance-fy2026-\d{8}-\d{6}\.csv$/',
            $this->csvFilename('variance', 2026)
        );
    }

    public function test_the_filename_never_carries_a_username(): void
    {
        $name = $this->csvFilename('encumbered-details', 2026);

        $this->assertStringNotContainsStringIgnoringCase('kcharles', $name);
        $this->assertSame(1, substr_count($name, '.'));
    }

    // =========================================================================
    // Month headings (ResolvesFiscalYear) — the Oct -> Sep boundary
    // =========================================================================

    // =========================================================================
    // postedCutoff — elapsed vs actually posted
    // =========================================================================

    /** @return array<int,array<string,float>> rows populated up to $through */
    private function rowsPopulatedThrough(int $through): array
    {
        $row = [];
        foreach (self::MONTH_KEYS as $i => $key) {
            $row[$key] = ($i + 1) <= $through ? 100.0 : 0.0;
        }

        return [$row];
    }

    private const MONTH_KEYS = ['Oct', 'Nov', 'Dec', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep'];

    public function test_the_current_year_is_capped_at_the_last_posted_period(): void
    {
        // 29 Aug 2026 is fiscal period 11 of FY2026, but only July has posted.
        CarbonImmutable::setTestNow(CarbonImmutable::parse('2026-08-29'));

        $this->assertSame(11, $this->resolveCutoff(2026), 'sanity: 11 periods have elapsed');
        $this->assertSame(
            10,
            $this->postedCutoff(2026, $this->rowsPopulatedThrough(10), self::MONTH_KEYS),
            'August has not posted, so the boundary is July.'
        );
    }

    public function test_the_cap_never_hides_a_month_that_has_posted(): void
    {
        // The guard against capping too early: once August posts mid-month it
        // must appear, not be blanked as "not started".
        CarbonImmutable::setTestNow(CarbonImmutable::parse('2026-08-29'));

        $this->assertSame(
            11,
            $this->postedCutoff(2026, $this->rowsPopulatedThrough(11), self::MONTH_KEYS)
        );
    }

    public function test_the_cap_never_exceeds_the_elapsed_cutoff(): void
    {
        // Data cannot post into the future; if it somehow did, the elapsed
        // cutoff still wins.
        CarbonImmutable::setTestNow(CarbonImmutable::parse('2026-08-29'));

        $this->assertSame(
            11,
            $this->postedCutoff(2026, $this->rowsPopulatedThrough(12), self::MONTH_KEYS)
        );
    }

    public function test_a_completed_year_is_never_capped(): void
    {
        // THE RULE THAT PROTECTS REAL ZEROS. A finished year whose September was
        // genuinely empty must keep its 0.00 — blanking it would invent an
        // absence out of a real measurement.
        CarbonImmutable::setTestNow(CarbonImmutable::parse('2026-08-29'));

        $this->assertSame(
            12,
            $this->postedCutoff(2025, $this->rowsPopulatedThrough(6), self::MONTH_KEYS)
        );
    }

    public function test_a_future_year_shows_nothing(): void
    {
        CarbonImmutable::setTestNow(CarbonImmutable::parse('2026-08-29'));

        $this->assertSame(
            0,
            $this->postedCutoff(2027, $this->rowsPopulatedThrough(0), self::MONTH_KEYS)
        );
    }

    public function test_a_zero_month_mid_year_does_not_end_the_year_early(): void
    {
        // December genuinely spent nothing; January onward did. The boundary is
        // the LAST populated period, not the first gap.
        CarbonImmutable::setTestNow(CarbonImmutable::parse('2026-08-29'));

        $rows = $this->rowsPopulatedThrough(10);
        $rows[0]['Dec'] = 0.0;

        $this->assertSame(10, $this->postedCutoff(2026, $rows, self::MONTH_KEYS));
    }

    public function test_the_boundary_is_taken_across_all_rows_not_just_the_first(): void
    {
        // One account posting in July is enough to make July posted for everyone.
        CarbonImmutable::setTestNow(CarbonImmutable::parse('2026-08-29'));

        $rows = array_merge(
            $this->rowsPopulatedThrough(3),
            $this->rowsPopulatedThrough(10),
        );

        $this->assertSame(10, $this->postedCutoff(2026, $rows, self::MONTH_KEYS));
    }

    public function test_a_negative_only_month_still_counts_as_posted(): void
    {
        // A credit note is activity. Testing "non-zero", not "positive".
        CarbonImmutable::setTestNow(CarbonImmutable::parse('2026-08-29'));

        $rows = $this->rowsPopulatedThrough(9);
        $rows[0]['Jul'] = -250.00;

        $this->assertSame(10, $this->postedCutoff(2026, $rows, self::MONTH_KEYS));
    }

    public function test_month_headings_carry_a_four_digit_year_across_the_boundary(): void
    {
        $headings = $this->fiscalMonthHeadings(2026);

        $this->assertCount(12, $headings);
        // Oct-Dec belong to the PRIOR calendar year; Jan onward to the named one.
        $this->assertSame('Oct 2025', $headings[0]);
        $this->assertSame('Dec 2025', $headings[2]);
        $this->assertSame('Jan 2026', $headings[3]);
        $this->assertSame('Sep 2026', $headings[11]);
    }
}
