<?php

namespace App\Http\Controllers;

use App\Concerns\DerivesRequisitionDetail;
use App\Concerns\ExportsReports;
use App\Concerns\ResolvesFiscalYear;
use App\Concerns\ResolvesLedgerAccess;
use App\Concerns\VersionsRequisitionCache;
use App\Models\FinanceLedger;
use App\Models\FinanceRequisition;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Illuminate\Pagination\LengthAwarePaginator;
use Illuminate\Support\Carbon;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;
use Inertia\Inertia;
use Inertia\Response;
use Symfony\Component\HttpFoundation\StreamedResponse;

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
    use ExportsReports;
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
        // Held outside the try so the outage path can still echo back what the
        // user asked for.
        $filters = $request->only('cluster', 'institution', 'department', 'account', 'vendor', 'status', 'fy');
        $currentFiscalYear = $this->currentFiscalYear();

        try {
            $r = $this->resolve($request);
        } catch (\Throwable $e) {
            return $this->unavailable($request, $filters, $currentFiscalYear, $e);
        }

        return Inertia::render($this->component(), [
            'rows' => $this->paginate($request, $r['rows']),
            'clusters' => $r['clusters'],
            'institutions' => $r['institutions'],
            'departments' => $r['departments'],
            'accounts' => $r['accounts'],
            'vendors' => $r['vendors'],
            'statuses' => $r['statuses'],
            'years' => $r['years'],
            // Totals over the whole filtered set, before pagination.
            'totals' => $this->requisitionTotals($r['rows']),
            'filters' => $r['filters'],
            'activeFiscalYear' => $r['activeFiscalYear'],
            'currentFiscalYear' => $currentFiscalYear,
            'hasAccess' => $r['hasAccess'],
            'snapshot' => $r['snapshot'],
            // Fiscal years the detail holds but the ledger does not, so the page
            // can say why they are absent rather than appearing to lose data.
            'unsummarisedYears' => $r['unsummarisedYears'],
        ]);
    }

    // =========================================================================
    // Export
    // =========================================================================

    /**
     * Defined once here, so both subclasses get their CSV with no edit — the
     * same reason this base exists at all. statuses() already keeps AP/PO and
     * RT/HD/PN from leaking into each other's file, and routeName() supplies
     * both the redirect target and the filename slug.
     */
    public function export(Request $request): StreamedResponse|RedirectResponse
    {
        try {
            $r = $this->resolve($request);
        } catch (\Throwable $e) {
            Log::error('Requisition detail export failed.', [
                'page' => $this->routeName(),
                'username' => $request->user()->username,
                'fy' => $request->input('fy'),
                'exception' => $e->getMessage(),
            ]);

            return $this->exportRedirect($request, $this->routeName(), self::EXPORT_UNAVAILABLE);
        }

        if (! $r['hasAccess']) {
            return $this->exportRedirect($request, $this->routeName(), self::EXPORT_NO_ACCESS);
        }

        if ($r['droppedFilters'] !== []) {
            return $this->exportRedirect($request, $this->routeName(), self::EXPORT_STALE_FILTER);
        }

        if ($r['rows']->isEmpty()) {
            return $this->exportRedirect($request, $this->routeName(), self::EXPORT_NO_ROWS);
        }

        Log::info('CSV export started.', [
            'page' => $this->routeName(),
            'username' => $request->user()->username,
            'fy' => $r['activeFiscalYear'],
            'filters' => array_filter($r['filters']),
            // The snapshot the file was cut from. Dropped as a COLUMN (it
            // repeated on every row for no analytical value) but kept here, so
            // the provenance of any exported file is still recoverable.
            'snapshot' => $r['snapshot']['refreshedAt'],
            'rows' => $r['rows']->count(),
        ]);

        return $this->streamCsv(
            $this->csvFilename($this->exportSlug(), $r['activeFiscalYear']),
            self::EXPORT_HEADINGS,
            fn () => $this->exportRows($r['rows']),
            ['page' => $this->routeName(), 'username' => $request->user()->username],
        );
    }

    /**
     * The 25 fetched columns — see export.md 5.4.
     *
     * ONE SCHEMA FOR BOTH PAGES, so the two files can be safely unioned.
     * PO Number is usually empty on routing rows; the column stays regardless.
     *
     * The eight columns the screen does not show are here on purpose: Order
     * Quantity and Quantity Shipped are what make the netted Extended Cost
     * independently auditable, and the table only exposes them in a tooltip.
     *
     * PartiallyReceived is deliberately absent — it is a derived UI flag for
     * muting a row, not data. So is the snapshot timestamp: it was the same
     * value on all 3,408 rows, which is padding rather than information. Both
     * pages still show the snapshot age on screen (SnapshotFreshness.vue), and
     * the export log records it per download.
     */
    private const EXPORT_HEADINGS = [
        'Financial Year', 'Requisition Number', 'PO Number', 'Line Number',
        'Status Code', 'Status Name', 'Date Created', 'Requisition Owner',
        'Vendor ID', 'Vendor Name', 'Item ID', 'Item Description', 'UofM',
        'Site Location', 'Cluster', 'Institution', 'Responsibility Centre', 'Department',
        'Account Number', 'Account Description',
        'Order Quantity', 'Quantity Shipped', 'Remaining Quantity', 'Unit Cost', 'Extended Cost',
    ];

    /**
     * Nothing here is re-derived. Remaining Quantity is the row's Quantity (the
     * view aliases ActBalance to it — the unshipped balance, floored at zero),
     * and Extended Cost is already net of receipts. Recomputing either in PHP
     * is what would break Phase 2's reconciliation guarantee silently.
     *
     * @param  Collection<int,array<string,mixed>>  $rows
     * @return \Generator<int,array<int,string>>
     */
    private function exportRows(Collection $rows): \Generator
    {
        foreach ($rows as $row) {
            yield [
                $this->csvText($row['FinancialYear']),
                $this->csvText($row['RequisitionNumber']),
                $this->csvText($row['PONumber']),
                $this->csvText($row['LineNbr']),
                $this->csvText($row['Status']),
                $this->csvText($row['StatusName']),
                $this->csvDate($row['ReqDateCreated']),
                $this->csvText($row['Name']),
                $this->csvText($row['VendorID']),
                $this->csvText($row['VendorName']),
                $this->csvText($row['ItemID']),
                $this->csvText($row['ItemDescription']),
                $this->csvText($row['UofM']),
                $this->csvText($row['SiteLocation']),
                $this->csvText($row['Cluster']),
                $this->csvText($row['Institution']),
                $this->csvText($row['ResponsibilityCentre']),
                $this->csvText($row['Department']),
                $this->csvText($row['AccountNumber']),
                $this->csvText($row['AccountDescription']),
                $this->csvQuantity($row['OrderQuantity']),
                $this->csvQuantity($row['QtyShipped']),
                $this->csvQuantity($row['Quantity']),
                $this->csvMoney($row['UnitCost']),
                $this->csvMoney($row['ExtendedCost']),
            ];
        }
    }

    /** Filename slug — "encumbered-details" from "encumbered-details.index". */
    private function exportSlug(): string
    {
        return (string) preg_replace('/\.index$/', '', $this->routeName());
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
     *               years:array<int,string>, unsummarisedYears:array<int,string>,
     *               hasAccess:bool,
     *               snapshot:array{refreshedAt:string|null,age:string|null},
     *               clusters:array, institutions:array, departments:array,
     *               accounts:array, vendors:array, statuses:array}
     */
    private function resolve(Request $request): array
    {
        $username = $request->user()->username;
        $filters = $request->only('cluster', 'institution', 'department', 'account', 'vendor', 'status', 'fy');
        $currentFiscalYear = $this->currentFiscalYear();

        $yearData = $this->availableYears($username);
        $years = collect($yearData['years']);

        $activeFiscalYear = $this->resolveFiscalYear($request->input('fy'), $years, $currentFiscalYear);
        $filters['fy'] = $activeFiscalYear;

        $hasAccess = $this->userHasLedgerAccess($username);
        $rows = $this->detailRows($username, (string) $activeFiscalYear);
        $snapshot = $this->snapshotFreshness();

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
        // stale filter carried across an FY switch never silently empties the
        // table. A non-empty invalid value lands in $dropped: index() ignores
        // it, export() refuses on it.
        $filtered = $rows;
        $dropped = [];

        $filters['cluster'] = $this->validFilter($request, 'cluster', $clusters, $dropped);
        if ($filters['cluster']) {
            $filtered = $filtered->where('Cluster', $filters['cluster']);
        }

        $filters['institution'] = $this->validFilter($request, 'institution', array_column($institutions, 'Institution'), $dropped);
        if ($filters['institution']) {
            $filtered = $filtered->where('Institution', $filters['institution']);
        }

        $filters['department'] = $this->validFilter($request, 'department', $departments, $dropped);
        if ($filters['department']) {
            $filtered = $filtered->where('Department', $filters['department']);
        }

        $filters['account'] = $this->validFilter($request, 'account', array_column($accounts, 'AccountNumber'), $dropped);
        if ($filters['account']) {
            $filtered = $filtered->where('AccountNumber', $filters['account']);
        }

        $filters['vendor'] = $this->validFilter($request, 'vendor', $vendors, $dropped);
        if ($filters['vendor']) {
            $filtered = $filtered->where('VendorName', $filters['vendor']);
        }

        $filters['status'] = $this->validFilter($request, 'status', array_column($statuses, 'Status'), $dropped);
        if ($filters['status']) {
            $filtered = $filtered->where('Status', $filters['status']);
        }

        return [
            'rows' => $filtered->values(),
            'filters' => $filters,
            'droppedFilters' => $dropped,
            'activeFiscalYear' => $activeFiscalYear,
            'years' => $years->all(),
            'unsummarisedYears' => $yearData['unsummarised'],
            'hasAccess' => $hasAccess,
            'snapshot' => $snapshot,
            'clusters' => $clusters,
            'institutions' => $institutions,
            'departments' => $departments,
            'accounts' => $accounts,
            'vendors' => $vendors,
            'statuses' => $statuses,
        ];
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
            // True on an outage: the access probe could not run, so we do not
            // know, and must not tell the user they have no permissions.
            'hasAccess' => true,
            'snapshot' => ['refreshedAt' => null, 'age' => null],
            'unsummarisedYears' => [],
        ]);
    }
}
