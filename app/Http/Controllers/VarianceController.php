<?php

namespace App\Http\Controllers;

use App\Concerns\DerivesAllocationLines;
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
 * Variance — allocation against actual spend, per account line, for a fiscal
 * year. Renamed from "Allocation Line Expenditure"; the row grain is still the
 * allocation LINE, which is why DerivesAllocationLines keeps its name.
 *
 * Reads dbo.vw_FinanceLedger. Since 2026-08-25 the allocation rule is:
 *
 *     ActualExpenditure = YTDTotal + Approved
 *     Excess            = MAX(0, YTDTotal - Allocation)
 *     AllocationBalance = MAX(0, Allocation - YTDTotal)
 *
 * so the balance is measured against POSTED GL SPEND alone. Approved is shown
 * and counted into the reported "actual" but does not reduce the balance;
 * Routing does neither and is carried for information. The page therefore
 * reconciles on screen — Allocation minus YTD Expenditure IS the balance — and
 * the Vue table says so in a tooltip, because a user who sees a larger "actual"
 * beside an unreduced balance will otherwise assume the page is broken.
 *
 * The arithmetic itself lives in DerivesAllocationLines so it can be unit
 * tested without SQL Server; see financesqlupdate.md to revert the rule.
 */
class VarianceController extends Controller
{
    use DerivesAllocationLines;
    use ExportsReports;
    use ResolvesFiscalYear;
    use ResolvesLedgerAccess;
    use VersionsLedgerCache;

    /** Fiscal month columns in period order — PeriodID 1 = Oct … 12 = Sep. */
    public const MONTHS = FinanceLedger::MONTHS;

    private const PER_PAGE = 25;

    /** On-screen wording for the server-computed StatusKey. */
    private const STATUS_LABELS = [
        'over' => 'Exceeded',
        'under' => 'Under budget',
        'exact' => 'Fully spent',
    ];

    public function index(Request $request): Response
    {
        $filters = $request->only('cluster', 'institution', 'department', 'description', 'account', 'fy');
        $currentFiscalYear = $this->currentFiscalYear();

        try {
            $r = $this->resolve($request);
        } catch (\Throwable $e) {
            return $this->unavailable($request, $filters, $currentFiscalYear, $e);
        }

        $filtered = $r['rows'];

        // ── Totals over the whole filtered set, before pagination ────────────────
        // A totals row that only summed the visible page would look authoritative
        // and be wrong.
        $totals = $this->allocationTotals($filtered, self::MONTHS);

        $stats = [
            'totalAllocation' => $totals['allocation'],
            'totalExpenditure' => $totals['ytd'],
            'balance' => $totals['balance'],
            'exceededCount' => $totals['exceededCount'],
            'accountCount' => $filtered->count(),
        ];

        return Inertia::render('Expenditure/Variance', [
            'rows' => $this->paginate($request, $filtered),
            'clusters' => $r['clusters'],
            'institutions' => $r['institutions'],
            'departments' => $r['departments'],
            'descriptions' => $r['descriptions'],
            'accounts' => $r['accounts'],
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
            Log::error('Variance export failed.', [
                'username' => $request->user()->username,
                'fy' => $request->input('fy'),
                'exception' => $e->getMessage(),
            ]);

            return $this->exportRedirect($request, 'variance.index', self::EXPORT_UNAVAILABLE);
        }

        if (! $r['hasAccess']) {
            return $this->exportRedirect($request, 'variance.index', self::EXPORT_NO_ACCESS);
        }

        if ($r['droppedFilters'] !== []) {
            return $this->exportRedirect($request, 'variance.index', self::EXPORT_STALE_FILTER);
        }

        if ($r['rows']->isEmpty()) {
            return $this->exportRedirect($request, 'variance.index', self::EXPORT_NO_ROWS);
        }

        $fy = (int) $r['activeFiscalYear'];

        Log::info('CSV export started.', [
            'page' => 'variance',
            'username' => $request->user()->username,
            'fy' => $fy,
            'filters' => array_filter($r['filters']),
            'rows' => $r['rows']->count(),
        ]);

        return $this->streamCsv(
            $this->csvFilename('variance', $fy),
            $this->exportHeadings($fy),
            fn () => $this->exportRows($r['rows'], $r['monthCutoff']),
            ['page' => 'variance', 'username' => $request->user()->username],
        );
    }

    /**
     * 28 columns. This order is an API contract — see export.md section 5.3.
     *
     * Responsibility is included even though the screen omits it: it is what
     * distinguishes two rows sharing an account number across access
     * dimensions, and without it the file shows apparent duplicates.
     *
     * @return array<int,string>
     */
    private function exportHeadings(int $fiscalYear): array
    {
        return array_merge(
            ['Financial Year', 'Cluster', 'Institution', 'Responsibility', 'Department',
                'Account Number', 'Account Description', 'Allocation'],
            $this->fiscalMonthHeadings($fiscalYear),
            ['YTD Expenditure', 'Approved', 'Routing', 'Actual Expenditure',
                'Excess', 'Allocation Balance', 'Budget Status', 'Budget Status Amount'],
        );
    }

    /**
     * Every value here already exists on the row DerivesAllocationLines
     * produced. Nothing is re-derived — the money rule lives in SQL and in that
     * trait, and restating it here is exactly how a CSV starts disagreeing with
     * the screen it came from.
     *
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
                    $this->csvMoney($row['Allocation']),
                ],
                $months,
                [
                    $this->csvMoney($row['YTDTotal']),
                    $this->csvMoney($row['Approved']),
                    $this->csvMoney($row['Routing']),
                    $this->csvMoney($row['ActualExpenditure']),
                    $this->csvMoney($row['Excess']),
                    $this->csvMoney($row['AllocationBalance']),
                    $this->csvText(self::STATUS_LABELS[$row['StatusKey']] ?? $row['StatusKey']),
                    $this->csvMoney($row['StatusAmount']),
                ],
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
     *               clusters:array, institutions:array, departments:array,
     *               descriptions:array, accounts:array}
     */
    private function resolve(Request $request): array
    {
        $username = $request->user()->username;
        $filters = $request->only('cluster', 'institution', 'department', 'description', 'account', 'fy');
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

        $filters['department'] = $this->validFilter($request, 'department', $departments, $dropped);
        if ($filters['department']) {
            $filtered = $filtered->where('DepartmentName', $filters['department']);
        }

        $filters['description'] = $this->validFilter($request, 'description', $descriptions, $dropped);
        if ($filters['description']) {
            $filtered = $filtered->where('AccountDescription', $filters['description']);
        }

        $filters['account'] = $this->validFilter($request, 'account', array_column($accounts, 'AccountNumber'), $dropped);
        if ($filters['account']) {
            $filtered = $filtered->where('AccountNumber', $filters['account']);
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
            'departments' => $departments,
            'descriptions' => $descriptions,
            'accounts' => $accounts,
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
            ->map(fn ($row) => $this->deriveAllocationLine(
                (array) $row->getAttributes(), $columns, self::MONTHS
            ));
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

        return Inertia::render('Expenditure/Variance', [
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
            // Same key set as the success path, zeroed — asserted by the unit
            // suite, because a prop present on one path and missing on the
            // other is a Vue error stacked on top of an outage.
            'totals' => $this->emptyAllocationTotals(self::MONTHS),
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
