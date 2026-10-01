<?php

namespace App\Http\Controllers;

use App\Concerns\ExportsReports;
use App\Concerns\ResolvesFiscalYear;
use App\Concerns\ResolvesLedgerAccess;
use App\Concerns\VersionsLedgerCache;
use App\Models\FinanceLedger;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Illuminate\Pagination\LengthAwarePaginator;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Log;
use Inertia\Inertia;
use Inertia\Response;
use Symfony\Component\HttpFoundation\StreamedResponse;

/**
 * Monthly Expenditure — one row per account for a fiscal year, with the 12
 * fiscal months across and a YTD total.
 *
 * This page took the name (and the /monthly-expenditure URL) from the retired
 * per-period page that read dbo.MonthlyExpenditure. Same money, better grain.
 *
 * Reads dbo.vw_FinanceLedger, which already carries the months pivoted, so the
 * page needs one query per request instead of one row per account per period.
 * The per-user set is small (the ledger is scoped to the departments a user's
 * positions grant), so the filter option lists, stats and pagination are all
 * derived in memory from that one result — the same shape
 * BudgetAllocationController uses.
 */
class MonthlyExpenditureController extends Controller
{
    use ExportsReports;
    use ResolvesFiscalYear;
    use ResolvesLedgerAccess;
    use VersionsLedgerCache;

    /** Fiscal month columns in period order — PeriodID 1 = Oct … 12 = Sep. */
    public const MONTHS = FinanceLedger::MONTHS;

    private const PER_PAGE = 25;

    public function index(Request $request): Response
    {
        // Held outside the try so the outage path can still echo back what the
        // user asked for.
        $filters = $request->only('cluster', 'institution', 'responsibility', 'department', 'fy');
        $currentFiscalYear = $this->currentFiscalYear();

        try {
            $r = $this->resolve($request);
        } catch (\Throwable $e) {
            return $this->unavailable($request, $filters, $currentFiscalYear, $e);
        }

        $filtered = $r['rows'];

        // ── Stats and column totals over the whole filtered set ──────────────────
        // Deliberately computed before pagination: a totals row that only summed
        // the visible 25 rows would look authoritative and be wrong.
        $monthTotals = [];
        foreach (self::MONTHS as $m) {
            $monthTotals[$m] = round((float) $filtered->sum($m), 2);
        }

        // Ranked on a copy — sorting $monthTotals itself would destroy the fiscal
        // month ordering the totals row depends on.
        $highestMonthKey = null;
        if ($filtered->isNotEmpty()) {
            $ranked = $monthTotals;
            arsort($ranked);
            $highestMonthKey = array_key_first($ranked);
        }

        $grandTotal = round((float) $filtered->sum('YTDTotal'), 2);

        $stats = [
            'totalExpenditure' => $grandTotal,
            'highestMonth' => [
                'label' => $highestMonthKey ? $this->monthLabel($highestMonthKey, (int) $r['activeFiscalYear']) : null,
                'amount' => $highestMonthKey ? $monthTotals[$highestMonthKey] : 0.0,
            ],
            'accountCount' => $filtered->count(),
        ];

        $totals = [
            'months' => $monthTotals,
            'ytd' => $grandTotal,
        ];

        return Inertia::render('Expenditure/Monthly Expenditure', [
            'rows' => $this->paginate($request, $filtered),
            'clusters' => $r['clusters'],
            'institutions' => $r['institutions'],
            'responsibilities' => $r['responsibilities'],
            'departments' => $r['departments'],
            'years' => $r['years'],
            // The same cutoff the CSV blanks against, so the screen and the
            // file cannot disagree about which months have posted.
            'months' => $this->monthHeadings((int) $r['activeFiscalYear'], $r['monthCutoff']),
            'stats' => $stats,
            'totals' => $totals,
            'filters' => $r['filters'],
            'activeFiscalYear' => $r['activeFiscalYear'],
            'currentFiscalYear' => $currentFiscalYear,
            'fyNav' => $r['fyNav'],
            'hasAccess' => $r['hasAccess'],
        ]);
    }

    // =========================================================================
    // Export
    // =========================================================================

    public function export(Request $request): StreamedResponse|RedirectResponse
    {
        try {
            $r = $this->resolve($request);
        } catch (\Throwable $e) {
            Log::error('Monthly expenditure export failed.', [
                'username' => $request->user()->username,
                'fy' => $request->input('fy'),
                'exception' => $e->getMessage(),
            ]);

            return $this->exportRedirect($request, 'monthly-expenditure.index', self::EXPORT_UNAVAILABLE);
        }

        if (! $r['hasAccess']) {
            return $this->exportRedirect($request, 'monthly-expenditure.index', self::EXPORT_NO_ACCESS);
        }

        if ($r['droppedFilters'] !== []) {
            return $this->exportRedirect($request, 'monthly-expenditure.index', self::EXPORT_STALE_FILTER);
        }

        if ($r['rows']->isEmpty()) {
            return $this->exportRedirect($request, 'monthly-expenditure.index', self::EXPORT_NO_ROWS);
        }

        $fy = (int) $r['activeFiscalYear'];

        Log::info('CSV export started.', [
            'page' => 'monthly-expenditure',
            'username' => $request->user()->username,
            'fy' => $fy,
            'filters' => array_filter($r['filters']),
            'rows' => $r['rows']->count(),
        ]);

        return $this->streamCsv(
            $this->csvFilename('monthly-expenditure', $fy),
            $this->exportHeadings($fy),
            fn () => $this->exportRows($r['rows'], $r['monthCutoff']),
            ['page' => 'monthly-expenditure', 'username' => $request->user()->username],
        );
    }

    /**
     * 20 columns. This order is an API contract — see export.md section 5.2.
     *
     * Cluster, Responsibility and Financial Year are fetched today for
     * filtering but not displayed. A CSV is a data export, not a screenshot, so
     * they are included.
     *
     * @return array<int,string>
     */
    private function exportHeadings(int $fiscalYear): array
    {
        return array_merge(
            ['Financial Year', 'Cluster', 'Institution', 'Responsibility', 'Department',
                'Account Number', 'Account Description'],
            $this->fiscalMonthHeadings($fiscalYear),
            ['YTD Net Expenditure'],
        );
    }

    /**
     * @param  Collection<int,array<string,mixed>>  $rows
     * @return \Generator<int,array<int,string>>
     */
    private function exportRows(Collection $rows, int $cutoff): \Generator
    {
        foreach ($rows as $row) {
            $months = [];
            foreach (self::MONTHS as $i => $month) {
                // A month that has not happened is not a month with no spend.
                $months[] = ($i + 1) > $cutoff ? '' : $this->csvMoney($row[$month]);
            }

            yield array_merge(
                [
                    $this->csvText($row['FinancialYear']),
                    $this->csvText($row['ClusterName']),
                    $this->csvText($row['InstitutionName']),
                    $this->csvText($row['Responsibility']),
                    $this->csvText($row['DepartmentName']),
                    $this->csvText($row['AccountNumber']),
                    $this->csvText($row['AccountDescription']),
                ],
                $months,
                [$this->csvMoney($row['YTDTotal'])],
            );
        }
    }

    // =========================================================================
    // Shared resolution
    // =========================================================================

    /**
     * Everything index() and export() both need — a pure lift of what used to
     * be inline in index(), extracted so the screen and the CSV cannot drift.
     *
     * Throws on any SQL failure; the caller decides whether that renders an
     * empty page or redirects.
     *
     * @return array{rows:Collection<int,array<string,mixed>>, filters:array<string,mixed>,
     *               droppedFilters:array<int,string>, activeFiscalYear:?int,
     *               years:array<int,string>, fyNav:array{prev:?int,next:?int}, hasAccess:bool,
     *               clusters:array, institutions:array, responsibilities:array, departments:array}
     */
    private function resolve(Request $request): array
    {
        $username = $request->user()->username;
        $filters = $request->only('cluster', 'institution', 'responsibility', 'department', 'fy');
        $currentFiscalYear = $this->currentFiscalYear();

        $years = collect($this->availableYears($username));

        $activeFiscalYear = $this->resolveFiscalYear($request->input('fy'), $years, $currentFiscalYear);
        $fyNav = $this->fiscalYearNav($activeFiscalYear, $years);
        $filters['fy'] = $activeFiscalYear;

        $hasAccess = $this->userHasLedgerAccess($username);
        $rows = $this->ledgerRows($username, (string) $activeFiscalYear);

        // Derived from the UNFILTERED year, so the month boundary is a property
        // of the posting calendar rather than of the current filter selection.
        $monthCutoff = $this->postedCutoff((int) $activeFiscalYear, $rows, self::MONTHS);

        // ── Filter option lists (scoped to what the active FY actually contains) ──
        $clusters = $rows->pluck('ClusterName')->filter()->unique()->sort()->values()->all();

        $institutions = $rows
            ->map(fn ($r) => ['ClusterName' => $r['ClusterName'], 'InstitutionName' => $r['InstitutionName']])
            ->unique(fn ($i) => $i['ClusterName'].'|'.$i['InstitutionName'])
            ->sortBy('InstitutionName')
            ->values()
            ->all();

        $responsibilities = $rows->pluck('Responsibility')->filter()->unique()->sort()->values()->all();
        $departments = $rows->pluck('DepartmentName')->filter()->unique()->sort()->values()->all();

        // ── Apply filters ────────────────────────────────────────────────────────
        // Only honour a selection that is a valid option in the active FY, so a
        // stale filter carried across an FY switch never silently empties the
        // table. A non-empty invalid value lands in $dropped: index() ignores
        // it, export() refuses on it.
        $filtered = $rows;
        $dropped = [];

        $filters['cluster'] = $this->validFilter($request, 'cluster', $clusters, $dropped);
        if ($filters['cluster']) {
            $filtered = $filtered->where('ClusterName', $filters['cluster']);
        }

        $filters['institution'] = $this->validFilter($request, 'institution', array_column($institutions, 'InstitutionName'), $dropped);
        if ($filters['institution']) {
            $filtered = $filtered->where('InstitutionName', $filters['institution']);
        }

        $filters['responsibility'] = $this->validFilter($request, 'responsibility', $responsibilities, $dropped);
        if ($filters['responsibility']) {
            $filtered = $filtered->where('Responsibility', $filters['responsibility']);
        }

        $filters['department'] = $this->validFilter($request, 'department', $departments, $dropped);
        if ($filters['department']) {
            $filtered = $filtered->where('DepartmentName', $filters['department']);
        }

        return [
            'rows' => $filtered->values(),
            'monthCutoff' => $monthCutoff,
            'filters' => $filters,
            'droppedFilters' => $dropped,
            'activeFiscalYear' => $activeFiscalYear,
            'years' => $years->all(),
            'fyNav' => $fyNav,
            'hasAccess' => $hasAccess,
            'clusters' => $clusters,
            'institutions' => $institutions,
            'responsibilities' => $responsibilities,
            'departments' => $departments,
        ];
    }

    // =========================================================================
    // Ledger reads
    // =========================================================================

    /**
     * Fiscal years this user has ledger rows for. Cached per user, versioned by
     * the snapshot's refresh time so a rebuild invalidates it immediately.
     *
     * @return array<int,string>
     */
    private function availableYears(string $username): array
    {
        return Cache::store(config('ledger.cache.store'))->remember(
            $this->ledgerCacheKey("finance-ledger:years:{$username}"),
            config('ledger.cache.minutes') * 60,
            fn () => FinanceLedger::forUser($username)
                ->select('FinancialYear')
                ->distinct()
                ->orderBy('FinancialYear')
                ->pluck('FinancialYear')
                ->filter()
                ->values()
                ->all()
        );
    }

    /**
     * One row per account for the year, as plain arrays.
     *
     * Not cached: the table and its stats stay live, matching the other data
     * pages. Only the derived option lists are cached.
     *
     * @return Collection<int,array<string,mixed>>
     */
    private function ledgerRows(string $username, string $fiscalYear): Collection
    {
        $columns = array_merge(
            ['FinancialYear', 'ClusterName', 'InstitutionName', 'Responsibility', 'DepartmentName', 'AccountNumber', 'AccountDescription', 'YTDTotal'],
            self::MONTHS,
        );

        return FinanceLedger::forUser($username)
            ->forYear($fiscalYear)
            ->select($columns)
            ->orderBy('ClusterName')
            ->orderBy('InstitutionName')
            ->orderBy('DepartmentName')
            ->orderBy('AccountNumber')
            // Tiebreak, NOT cosmetic. Since the Access-parity change the ledger
            // can hold TWO rows for one AccountNumber (the GL and COA spellings
            // of its description differ), so AccountNumber alone is not a unique
            // ordering. Pagination is applied in memory over this order and the
            // CSV export streams the same set, so without a deterministic
            // tiebreak ?page=1 and ?page=2 can overlap or drop a row between
            // requests. See financeupdatesep.md B6.
            ->orderBy('AccountDescription')
            ->get()
            ->map(function ($row) use ($columns) {
                $out = [];
                foreach ($columns as $column) {
                    $out[$column] = in_array($column, self::MONTHS, true) || $column === 'YTDTotal'
                        ? (float) $row->{$column}
                        : $row->{$column};
                }

                return $out;
            });
    }

    // =========================================================================
    // Presentation helpers
    // =========================================================================

    /**
     * @param  Collection<int,array<string,mixed>>  $filtered
     */
    private function paginate(Request $request, Collection $filtered): LengthAwarePaginator
    {
        $page = LengthAwarePaginator::resolveCurrentPage();

        return new LengthAwarePaginator(
            $filtered->forPage($page, self::PER_PAGE)->values(),
            $filtered->count(),
            self::PER_PAGE,
            $page,
            ['path' => $request->url(), 'query' => $request->query()],
        );
    }

    /**
     * Column headings for the 12 fiscal months, e.g. ['key' => 'Oct',
     * 'label' => 'OCT', 'year' => '25', 'future' => false]. `future` lets the
     * page mute months that have not happened yet in the active fiscal year.
     *
     * @return array<int,array{key:string,label:string,year:string,future:bool,quarterStart:bool}>
     */
    private function monthHeadings(int $fiscalYear, ?int $cutoff = null): array
    {
        // Defaults to the elapsed cutoff for the outage path, which has no rows
        // to derive a posted cutoff from.
        $cutoff = $cutoff ?? $this->resolveCutoff($fiscalYear);
        $labels = $this->fiscalMonthLabels($fiscalYear);   // keyed 1..12, "OCT, 25"

        $out = [];
        foreach (self::MONTHS as $i => $key) {
            $periodId = $i + 1;
            [$abbr, $yy] = explode(', ', $labels[$periodId]);

            $out[] = [
                'key' => $key,
                'label' => $abbr,
                'year' => $yy,
                'future' => $periodId > $cutoff,
                'quarterStart' => $periodId % 3 === 1 && $periodId > 1,
            ];
        }

        return $out;
    }

    private function monthLabel(string $key, int $fiscalYear): string
    {
        $periodId = array_search($key, self::MONTHS, true) + 1;

        return $this->fiscalMonthLabels($fiscalYear)[$periodId] ?? strtoupper($key);
    }

    /**
     * SQL Server is unreachable — render an explicitly EMPTY page, never a
     * zero-valued one. A dashboard reading "TTD 0 spent" during an outage is
     * indistinguishable from a real answer; an empty table with a warning is not.
     */
    private function unavailable(Request $request, array $filters, int $currentFiscalYear, \Throwable $e): Response
    {
        Log::error('Department expenditure query failed.', [
            'username' => $request->user()->username,
            'fy' => $request->input('fy'),
            'exception' => $e->getMessage(),
        ]);

        session()->flash('warning', 'The financial data source is unavailable. Please try again later.');

        $filters['fy'] = $filters['fy'] ?? $currentFiscalYear;

        return Inertia::render('Expenditure/Monthly Expenditure', [
            'rows' => new LengthAwarePaginator([], 0, self::PER_PAGE, 1, [
                'path' => $request->url(),
                'query' => $request->query(),
            ]),
            'clusters' => [],
            'institutions' => [],
            'responsibilities' => [],
            'departments' => [],
            'years' => [],
            'months' => $this->monthHeadings((int) $filters['fy']),
            'stats' => [
                'totalExpenditure' => 0,
                'highestMonth' => ['label' => null, 'amount' => 0],
                'accountCount' => 0,
            ],
            'totals' => [
                'months' => array_fill_keys(self::MONTHS, 0),
                'ytd' => 0,
            ],
            'filters' => $filters,
            'activeFiscalYear' => $filters['fy'],
            'currentFiscalYear' => $currentFiscalYear,
            'fyNav' => ['prev' => null, 'next' => null],
            // True on an outage: we could not run the access probe, so we do not
            // know, and must not tell the user they have no permissions.
            'hasAccess' => true,
        ]);
    }
}
