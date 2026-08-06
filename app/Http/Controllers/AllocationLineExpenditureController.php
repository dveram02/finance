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
 * Allocation Line Expenditure — allocation against actual spend, per account
 * line, for a fiscal year.
 *
 * Reads dbo.vw_FinanceLedger, which computes Excess and AllocationBalance
 * against ActualExpenditure (YTD + Approved + Routing) rather than YTD alone —
 * money that is committed on an approved or routing requisition is no longer
 * available to spend, so counting only posted GL activity would overstate the
 * headroom on every line that has an open commitment.
 */
class AllocationLineExpenditureController extends Controller
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
        $filters = $request->only('cluster', 'institution', 'department', 'description', 'account', 'fy');
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

        // ── Filter option lists (scoped to what the active FY contains) ──────────
        $clusters = $rows->pluck('ClusterName')->filter()->unique()->sort()->values()->all();

        $institutions = $rows
            ->map(fn ($r) => ['ClusterName' => $r['ClusterName'], 'InstitutionName' => $r['InstitutionName']])
            ->unique(fn ($i) => $i['ClusterName'].'|'.$i['InstitutionName'])
            ->sortBy('InstitutionName')
            ->values()
            ->all();

        $departments = $rows->pluck('DepartmentName')->filter()->unique()->sort()->values()->all();
        $descriptions = $rows->pluck('AccountDescription')->filter()->unique()->sort()->values()->all();

        // Account numbers are shown with their description, since the number
        // alone is unreadable. Ordered by description so the list is scannable.
        $accounts = $rows
            ->map(fn ($r) => ['AccountNumber' => $r['AccountNumber'], 'AccountDescription' => $r['AccountDescription']])
            ->unique('AccountNumber')
            ->sortBy(fn ($a) => $a['AccountDescription'].$a['AccountNumber'])
            ->values()
            ->all();

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

        $filters['department'] = ($v = $request->input('department')) && in_array($v, $departments, true) ? $v : null;
        if ($filters['department']) {
            $filtered = $filtered->where('DepartmentName', $filters['department']);
        }

        $filters['description'] = ($v = $request->input('description')) && in_array($v, $descriptions, true) ? $v : null;
        if ($filters['description']) {
            $filtered = $filtered->where('AccountDescription', $filters['description']);
        }

        $filters['account'] = ($v = $request->input('account')) && in_array($v, array_column($accounts, 'AccountNumber'), true) ? $v : null;
        if ($filters['account']) {
            $filtered = $filtered->where('AccountNumber', $filters['account']);
        }

        $filtered = $filtered->values();

        // ── Totals over the whole filtered set, before pagination ────────────────
        // A totals row that only summed the visible page would look authoritative
        // and be wrong.
        $monthTotals = [];
        foreach (self::MONTHS as $month) {
            $monthTotals[$month] = round((float) $filtered->sum($month), 2);
        }

        $totalAllocation = round((float) $filtered->sum('Allocation'), 2);
        $totalYtd = round((float) $filtered->sum('YTDTotal'), 2);
        $exceededCount = $filtered->where('StatusKey', 'over')->count();

        $totals = [
            'allocation' => $totalAllocation,
            'months' => $monthTotals,
            'encumbered' => round((float) $filtered->sum('Encumbered'), 2),
            'ytd' => $totalYtd,
            // Summed per line, not derived from the totals: an account that has
            // overspent contributes zero balance, and netting it against another
            // account's headroom would overstate what is actually available.
            'balance' => round((float) $filtered->sum('AllocationBalance'), 2),
            'exceededCount' => $exceededCount,
        ];

        $stats = [
            'totalAllocation' => $totalAllocation,
            'totalExpenditure' => $totalYtd,
            'balance' => $totals['balance'],
            'exceededCount' => $exceededCount,
            'accountCount' => $filtered->count(),
        ];

        return Inertia::render('Expenditure/Allocation Line Expenditure', [
            'rows' => $this->paginate($request, $filtered),
            'clusters' => $clusters,
            'institutions' => $institutions,
            'departments' => $departments,
            'descriptions' => $descriptions,
            'accounts' => $accounts,
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
     * One row per account line for the year, as plain arrays.
     *
     * @return Collection<int,array<string,mixed>>
     */
    private function ledgerRows(string $username, string $fiscalYear): Collection
    {
        $columns = array_merge(
            [
                'FinancialYear', 'ClusterName', 'InstitutionName', 'Responsibility', 'DepartmentName',
                'AccountNumber', 'AccountDescription', 'Allocation', 'Approved', 'Routing',
                'YTDTotal', 'ActualExpenditure', 'Excess', 'AllocationBalance',
            ],
            self::MONTHS,
        );

        $numeric = array_merge(
            ['Allocation', 'Approved', 'Routing', 'YTDTotal', 'ActualExpenditure', 'Excess', 'AllocationBalance'],
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
            ->map(function ($row) use ($columns, $numeric) {
                $out = [];
                foreach ($columns as $column) {
                    $out[$column] = in_array($column, $numeric, true)
                        ? (float) $row->{$column}
                        : $row->{$column};
                }

                // The page shows one Encumbered column; the ledger splits the
                // commitment into approved (AP + PO) and routing (RT + HD + PN).
                $out['Encumbered'] = round($out['Approved'] + $out['Routing'], 2);

                [$out['StatusKey'], $out['StatusAmount']] = $this->classify($out['Excess'], $out['AllocationBalance']);

                return $out;
            });
    }

    // =========================================================================
    // Allocation outcome — the rule the page exists to show
    // =========================================================================

    /**
     * Classify a line from the ledger's Excess / AllocationBalance pair.
     *
     * The view already floors the balance at zero and reports any overspend
     * separately as Excess, so exactly one of the two can be non-zero. Doing
     * the classification from those columns keeps the rule single-sourced in
     * SQL rather than restating the arithmetic here.
     *
     * @return array{0:string,1:float}
     */
    private function classify(float $excess, float $balance): array
    {
        // Both sides are rounded money, but comparing floats for exact equality
        // is still unsafe — half a cent of tolerance decides "fully spent".
        if ($excess >= 0.005) {
            return ['over', round($excess, 2)];
        }

        if ($balance >= 0.005) {
            return ['under', round($balance, 2)];
        }

        return ['exact', 0.0];
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

    /**
     * SQL Server is unreachable — render an explicitly EMPTY page, never a
     * zero-valued one. "TTD 0 allocated" during an outage is indistinguishable
     * from a real answer; an empty table with a warning is not.
     */
    private function unavailable(Request $request, array $filters, int $currentFiscalYear, \Throwable $e): Response
    {
        Log::error('Allocation line expenditure query failed.', [
            'username' => $request->user()->username,
            'fy' => $request->input('fy'),
            'exception' => $e->getMessage(),
        ]);

        session()->flash('warning', 'The financial data source is unavailable. Please try again later.');

        $filters['fy'] = $filters['fy'] ?? $currentFiscalYear;

        return Inertia::render('Expenditure/Allocation Line Expenditure', [
            'rows' => new LengthAwarePaginator([], 0, self::PER_PAGE, 1, [
                'path' => $request->url(),
                'query' => $request->query(),
            ]),
            'clusters' => [],
            'institutions' => [],
            'departments' => [],
            'descriptions' => [],
            'accounts' => [],
            'years' => [],
            'months' => $this->monthHeadings((int) $filters['fy']),
            'stats' => [
                'totalAllocation' => 0,
                'totalExpenditure' => 0,
                'balance' => 0,
                'exceededCount' => 0,
                'accountCount' => 0,
            ],
            'totals' => [
                'allocation' => 0,
                'months' => array_fill_keys(self::MONTHS, 0),
                'encumbered' => 0,
                'ytd' => 0,
                'balance' => 0,
                'exceededCount' => 0,
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
