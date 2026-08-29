<?php

namespace App\Http\Controllers;

use App\Concerns\DerivesRequisitionDetail;
use App\Concerns\ResolvesFiscalYear;
use App\Concerns\ResolvesLedgerAccess;
use App\Concerns\VersionsRequisitionCache;
use App\Models\FinanceLedger;
use App\Models\FinanceRequisition;
use Illuminate\Http\Request;
use Illuminate\Pagination\LengthAwarePaginator;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;
use Inertia\Inertia;
use Inertia\Response;

/**
 * Shared body of the two requisition detail pages (Phase 3).
 *
 * These are DRILL-DOWNS, not new data: the same money the ledger reports per
 * account as Approved and Routing, at requisition-line grain. Approved and
 * Routing get a page each rather than one page with a status toggle, because
 * the summary presents them as two separate figures and a drill-down should
 * land on the figure the reader clicked. Everything except the status set, the
 * component name and the copy is identical, so it lives here once.
 *
 * Read-only report controllers, so the flat shape in
 * .claude/context/controller-patterns.md applies: no service layer, no
 * validation, no ValidationException handling. One query, derive in memory —
 * the largest measured single user/FY set is 3,408 rows.
 */
abstract class RequisitionDetailController extends Controller
{
    use DerivesRequisitionDetail;
    use ResolvesFiscalYear;
    use ResolvesLedgerAccess;
    use VersionsRequisitionCache;

    private const PER_PAGE = 25;

    /** Columns read from dbo.vw_FinanceRequisitionDetail, in display order. */
    private const COLUMNS = [
        'FinancialYear', 'RequisitionNumber', 'PONumber', 'LineNbr',
        'Status', 'StatusName', 'ReqDateCreated', 'Name',
        'VendorID', 'VendorName', 'ItemID', 'ItemDescription', 'UofM',
        'SiteLocation', 'Cluster', 'Institution', 'ResponsibilityCentre', 'Department',
        'AccountNumber', 'AccountDescription',
        'OrderQuantity', 'QtyShipped', 'Quantity', 'UnitCost', 'ExtendedCost',
    ];

    /**
     * The statuses this page reports — one of FinanceRequisition's two sets.
     *
     * @return array<int,string>
     */
    abstract protected function statuses(): array;

    /** The Inertia component, spaces and capital P included. */
    abstract protected function component(): string;

    /** The named route. Used for the log context only. */
    abstract protected function routeName(): string;

    public function index(Request $request): Response
    {
        $username = $request->user()->username;
        $filters = $request->only('cluster', 'institution', 'department', 'account', 'vendor', 'status', 'fy');
        $currentFiscalYear = $this->currentFiscalYear();

        try {
            $yearData = $this->availableYears($username);
            $years = collect($yearData['years']);

            $activeFiscalYear = $this->resolveFiscalYear($request->input('fy'), $years, $currentFiscalYear);
            $fyNav = $this->fiscalYearNav($activeFiscalYear, $years);
            $filters['fy'] = $activeFiscalYear;

            $hasAccess = $this->userHasLedgerAccess($username);
            $rows = $this->detailRows($username, (string) $activeFiscalYear);
            $snapshot = $this->snapshotFreshness();
        } catch (\Throwable $e) {
            return $this->unavailable($request, $filters, $currentFiscalYear, $e);
        }

        // ── Filter option lists (scoped to what the active FY contains) ──────────
        $clusters = $rows->pluck('Cluster')->filter()->unique()->sort()->values()->all();

        $institutions = $rows
            ->map(fn ($r) => ['Cluster' => $r['Cluster'], 'Institution' => $r['Institution']])
            ->unique(fn ($i) => $i['Cluster'].'|'.$i['Institution'])
            ->sortBy('Institution')
            ->values()
            ->all();

        $departments = $rows->pluck('Department')->filter()->unique()->sort()->values()->all();
        $vendors = $rows->pluck('VendorName')->filter()->unique()->sort()->values()->all();

        // Account numbers are unreadable alone, so they are offered with their
        // description and ordered by it.
        $accounts = $rows
            ->map(fn ($r) => ['AccountNumber' => $r['AccountNumber'], 'AccountDescription' => $r['AccountDescription']])
            ->unique('AccountNumber')
            ->sortBy(fn ($a) => $a['AccountDescription'].$a['AccountNumber'])
            ->values()
            ->all();

        // Statuses WITHIN this page's set — AP and PO are both "approved" but
        // mean different things to a buyer, and only those present in the year
        // are offered.
        $statuses = $rows
            ->map(fn ($r) => ['Status' => $r['Status'], 'StatusName' => $r['StatusName']])
            ->unique('Status')
            ->sortBy('Status')
            ->values()
            ->all();

        // ── Apply filters ────────────────────────────────────────────────────────
        // Only honour a selection that is a valid option in the active FY, so a
        // stale filter carried across an FY switch never silently empties the table.
        $filtered = $rows;

        $filters['cluster'] = ($v = $request->input('cluster')) && in_array($v, $clusters, true) ? $v : null;
        if ($filters['cluster']) {
            $filtered = $filtered->where('Cluster', $filters['cluster']);
        }

        $filters['institution'] = ($v = $request->input('institution')) && in_array($v, array_column($institutions, 'Institution'), true) ? $v : null;
        if ($filters['institution']) {
            $filtered = $filtered->where('Institution', $filters['institution']);
        }

        $filters['department'] = ($v = $request->input('department')) && in_array($v, $departments, true) ? $v : null;
        if ($filters['department']) {
            $filtered = $filtered->where('Department', $filters['department']);
        }

        $filters['account'] = ($v = $request->input('account')) && in_array($v, array_column($accounts, 'AccountNumber'), true) ? $v : null;
        if ($filters['account']) {
            $filtered = $filtered->where('AccountNumber', $filters['account']);
        }

        $filters['vendor'] = ($v = $request->input('vendor')) && in_array($v, $vendors, true) ? $v : null;
        if ($filters['vendor']) {
            $filtered = $filtered->where('VendorName', $filters['vendor']);
        }

        $filters['status'] = ($v = $request->input('status')) && in_array($v, array_column($statuses, 'Status'), true) ? $v : null;
        if ($filters['status']) {
            $filtered = $filtered->where('Status', $filters['status']);
        }

        $filtered = $filtered->values();

        return Inertia::render($this->component(), [
            'rows' => $this->paginate($request, $filtered),
            'clusters' => $clusters,
            'institutions' => $institutions,
            'departments' => $departments,
            'accounts' => $accounts,
            'vendors' => $vendors,
            'statuses' => $statuses,
            'years' => $years->all(),
            // Totals over the whole filtered set, before pagination.
            'totals' => $this->requisitionTotals($filtered),
            'filters' => $filters,
            'activeFiscalYear' => $activeFiscalYear,
            'currentFiscalYear' => $currentFiscalYear,
            'fyNav' => $fyNav,
            'hasAccess' => $hasAccess,
            'snapshot' => $snapshot,
            // Fiscal years the detail holds but the ledger does not, so the page
            // can say why they are absent rather than appearing to lose data.
            'unsummarisedYears' => $yearData['unsummarised'],
        ]);
    }

    // =========================================================================
    // Reads
    // =========================================================================

    /**
     * The fiscal years this page offers, and the ones deliberately withheld.
     *
     * THE RAIL IS BOUNDED TO YEARS THE LEDGER ALSO HAS. Measured on production
     * 2026-08-27, the requisition snapshot holds FY2010-FY2026 while the ledger
     * holds FY2014-FY2026 — 9,174 rows across four fiscal years that have no
     * summary at all. That is correct source behaviour (the same way
     * vw_BudgetAllocation starts at FY2025 while MonthlyExpenditure goes back to
     * FY2014), but offering those years here would let a user drill into detail
     * that reconciles against nothing and cannot be navigated back from.
     *
     * They are RETURNED, not silently dropped: the page names them, so the
     * absence reads as a documented boundary rather than lost data.
     *
     * Two caches, deliberately keyed to two different snapshots — the detail
     * years against the requisition refresh, the ledger years against the
     * ledger's. The second reuses the key VarianceController
     * writes, the same way DashboardController shares the budget years key.
     *
     * @return array{years:array<int,string>,unsummarised:array<int,string>}
     */
    private function availableYears(string $username): array
    {
        $store = Cache::store(config('ledger.cache.store'));

        $detailYears = $store->remember(
            $this->requisitionCacheKey("finance-requisition:years:{$username}:".$this->routeName()),
            config('ledger.requisition.cache_minutes') * 60,
            fn () => FinanceRequisition::forUser($username)
                ->withStatuses($this->statuses())
                ->select('FinancialYear')
                ->distinct()
                ->orderBy('FinancialYear')
                ->pluck('FinancialYear')
                ->filter()
                ->map(fn ($y) => (string) $y)
                ->values()
                ->all()
        );

        $ledgerYears = $store->remember(
            "finance-ledger:years:{$username}:v".$this->ledgerYearsVersion(),
            config('ledger.cache.minutes') * 60,
            fn () => FinanceLedger::forUser($username)
                ->select('FinancialYear')
                ->distinct()
                ->orderBy('FinancialYear')
                ->pluck('FinancialYear')
                ->filter()
                ->map(fn ($y) => (string) $y)
                ->values()
                ->all()
        );

        return [
            'years' => array_values(array_intersect($detailYears, $ledgerYears)),
            'unsummarised' => array_values(array_diff($detailYears, $ledgerYears)),
        ];
    }

    /**
     * The LEDGER's version stamp, for the ledger years key only.
     *
     * Deliberately not VersionsLedgerCache: mixing both traits into one class
     * gives two near-identical method names and invites versioning the
     * requisition lists against the wrong table, which is the single mistake
     * financesqlupdatep3.md calls out. The ledger years are read here as a
     * BOUND on the rail, not as this page's data, so they carry the ledger's
     * own stamp and share the ledger's cache entry.
     */
    private function ledgerYearsVersion(): string
    {
        return Cache::store(config('ledger.cache.store'))->remember(
            'finance-ledger:version',
            config('ledger.cache.version_seconds'),
            function () {
                try {
                    $value = DB::connection('FinanceAutomationSystem')
                        ->table('FinanceLedgerRefresh')
                        ->where('Outcome', 'OK')
                        ->max('RefreshedAt');

                    return $value === null ? 'none' : md5((string) $value);
                } catch (\Throwable $e) {
                    Log::warning('Finance ledger version probe failed; falling back to an unversioned cache key.', [
                        'exception' => $e->getMessage(),
                    ]);

                    return 'unknown';
                }
            }
        );
    }

    /**
     * Every detail line for the user, year and status set, as plain arrays.
     *
     * UNCACHED, like every other table query in this app — only the dropdown
     * lists are cached. Ordered so a reader scanning by requisition sees its
     * lines together.
     *
     * @return Collection<int,array<string,mixed>>
     */
    private function detailRows(string $username, string $fiscalYear): Collection
    {
        return FinanceRequisition::forUser($username)
            ->forYear($fiscalYear)
            ->withStatuses($this->statuses())
            ->select(self::COLUMNS)
            ->orderBy('Department')
            ->orderBy('RequisitionNumber')
            ->orderBy('LineNbr')
            ->get()
            ->map(fn ($row) => $this->deriveRequisitionRow((array) $row->getAttributes(), self::COLUMNS));
    }

    /**
     * When the detail was last built, for display.
     *
     * Phase 2 traded live data for reconciliation — a requisition raised at
     * 09:00 does not appear until the next refresh. The trade is only honest if
     * the page says so, so this is rendered on both pages rather than left
     * implicit.
     *
     * @return array{refreshedAt:string|null,age:string|null}
     */
    private function snapshotFreshness(): array
    {
        $refreshedAt = $this->requisitionRefreshedAt();

        if ($refreshedAt === null) {
            return ['refreshedAt' => null, 'age' => null];
        }

        $moment = Carbon::parse($refreshedAt);

        return [
            'refreshedAt' => $moment->toIso8601String(),
            'age' => $moment->diffForHumans(),
        ];
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
     * SQL Server is unreachable — render an explicitly EMPTY page, never a
     * zero-valued one. "TTD 0 committed" during an outage is indistinguishable
     * from a real answer; an empty table with a warning is not.
     *
     * The prop set here must match the success path key for key.
     */
    private function unavailable(Request $request, array $filters, int $currentFiscalYear, \Throwable $e): Response
    {
        Log::error('Requisition detail query failed.', [
            'page' => $this->routeName(),
            'username' => $request->user()->username,
            'fy' => $request->input('fy'),
            'exception' => $e->getMessage(),
        ]);

        session()->flash('warning', 'The financial data source is unavailable. Please try again later.');

        $filters['fy'] = $filters['fy'] ?? $currentFiscalYear;

        return Inertia::render($this->component(), [
            'rows' => new LengthAwarePaginator([], 0, self::PER_PAGE, 1, [
                'path' => $request->url(),
                'query' => $request->query(),
            ]),
            'clusters' => [],
            'institutions' => [],
            'departments' => [],
            'accounts' => [],
            'vendors' => [],
            'statuses' => [],
            'years' => [],
            'totals' => $this->emptyRequisitionTotals(),
            'filters' => $filters,
            'activeFiscalYear' => $filters['fy'],
            'currentFiscalYear' => $currentFiscalYear,
            'fyNav' => ['prev' => null, 'next' => null],
            // True on an outage: the access probe could not run, so we do not
            // know, and must not tell the user they have no permissions.
            'hasAccess' => true,
            'snapshot' => ['refreshedAt' => null, 'age' => null],
            'unsummarisedYears' => [],
        ]);
    }
}
