<?php

namespace App\Http\Controllers;

use App\Concerns\ResolvesFiscalYear;
use App\Concerns\ResolvesLedgerAccess;
use App\Concerns\VersionsLedgerCache;
use App\Models\FinanceLedger;
use Illuminate\Http\Request;
use Illuminate\Pagination\LengthAwarePaginator;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Log;
use Inertia\Inertia;
use Inertia\Response;

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
    use ResolvesFiscalYear;
    use ResolvesLedgerAccess;
    use VersionsLedgerCache;

    /** Fiscal month columns in period order — PeriodID 1 = Oct … 12 = Sep. */
    public const MONTHS = FinanceLedger::MONTHS;

    private const PER_PAGE = 25;

    public function index(Request $request): Response
    {
        $username = $request->user()->username;
        $filters = $request->only('cluster', 'institution', 'responsibility', 'department', 'fy');
        $currentFiscalYear = $this->currentFiscalYear();

        try {
            $years = collect($this->availableYears($username));

            $activeFiscalYear = $this->resolveFiscalYear($request->input('fy'), $years, $currentFiscalYear);
            $fyNav = $this->fiscalYearNav($activeFiscalYear, $years);
            $filters['fy'] = $activeFiscalYear;

            $hasAccess = $this->userHasLedgerAccess($username);
            $rows = $this->ledgerRows($username, (string) $activeFiscalYear);
        } catch (\Throwable $e) {
            return $this->unavailable($request, $filters, $currentFiscalYear, $e);
        }

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
        // stale filter carried across an FY switch never silently empties the table.
        $filtered = $rows;

        $filters['cluster'] = ($v = $request->input('cluster')) && in_array($v, $clusters, true) ? $v : null;
        if ($filters['cluster']) {
            $filtered = $filtered->where('ClusterName', $filters['cluster']);
        }

        $filters['institution'] = ($v = $request->input('institution')) && in_array($v, array_column($institutions, 'InstitutionName'), true) ? $v : null;
        if ($filters['institution']) {
            $filtered = $filtered->where('InstitutionName', $filters['institution']);
        }

        $filters['responsibility'] = ($v = $request->input('responsibility')) && in_array($v, $responsibilities, true) ? $v : null;
        if ($filters['responsibility']) {
            $filtered = $filtered->where('Responsibility', $filters['responsibility']);
        }

        $filters['department'] = ($v = $request->input('department')) && in_array($v, $departments, true) ? $v : null;
        if ($filters['department']) {
            $filtered = $filtered->where('DepartmentName', $filters['department']);
        }

        $filtered = $filtered->values();

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
                'label' => $highestMonthKey ? $this->monthLabel($highestMonthKey, (int) $activeFiscalYear) : null,
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
            'clusters' => $clusters,
            'institutions' => $institutions,
            'responsibilities' => $responsibilities,
            'departments' => $departments,
            'years' => $years->all(),
            'months' => $this->monthHeadings((int) $activeFiscalYear),
            'stats' => $stats,
            'totals' => $totals,
            'filters' => $filters,
            'activeFiscalYear' => $activeFiscalYear,
            'currentFiscalYear' => $currentFiscalYear,
            'fyNav' => $fyNav,
            'hasAccess' => $hasAccess,
        ]);
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
    private function monthHeadings(int $fiscalYear): array
    {
        $cutoff = $this->resolveCutoff($fiscalYear);
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
