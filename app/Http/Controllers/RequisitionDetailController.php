<?php

namespace App\Http\Controllers;

use App\Concerns\DerivesRequisitionDetail;
use App\Concerns\ExportsReports;
use App\Concerns\ResolvesFiscalYear;
use App\Concerns\ResolvesLedgerAccess;
use App\Concerns\VersionsRequisitionCache;
use App\Models\FinanceLedger;
use App\Models\FinanceRequisition;
use App\Support\RequisitionScopeThresholds;
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
 * validation, no ValidationException handling. One query, derive in memory.
 *
 * FISCAL YEAR IS AN OPTIONAL FILTER here (changed 2026-10-01, routingupdate.md).
 * The default scope is every ELIGIBLE year — the years this route's detail
 * shares with the ledger, which is 11 for Encumbered and 3 for Routing on the
 * only currently mapped user, never the snapshot's full FY2010-FY2026 range.
 * Because that scope is no longer bounded by one year, the single read is
 * bounded by a ROW CEILING instead: see fetchBoundedRows() and §6 of the plan.
 * Measured 2026-10-01: 416 rows for today's mapped user; 93,336 rows / 558 MB
 * for a hypothetical user mapped to every department, which the ceiling
 * refuses rather than truncates.
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

    // =========================================================================
    // Scope-guard copy
    //
    // Every sentence below has been checked against what the code actually
    // does, because three earlier drafts offered recoveries that do not exist.
    // Categorical filters CANNOT rescue an oversized scope: the bounded fetch
    // filters by user + year + status only, and the six categoricals are
    // applied in memory afterwards, so they never reach SQL. Year selection is
    // the only recovery, and it works — the largest single year snapshot-wide
    // is 18,945 rows against a 25,000 ceiling (measured 2026-10-01).
    // =========================================================================

    /** All-years is too large, and a year can be chosen instead. */
    protected const SCOPE_TOO_LARGE = 'This selection covers too many requisition lines to display. Choose a single fiscal year from the filters above.';

    /**
     * A SELECTED year is too large. No recovery exists on this page: the export
     * refuses the same scope, and filters cannot shrink it.
     */
    protected const SCOPE_TOO_LARGE_SINGLE_YEAR = 'This fiscal year has too many requisition lines to display or export. Choose another fiscal year, or contact IT — showing this one needs a change to how this page queries the data.';

    /**
     * Flashed on the all-years redirect. Carries a :year placeholder and MUST
     * be interpolated at the call site — passing it bare flashes a literal
     * "FY :year". It states what was SELECTED, not what is shown, which stays
     * true even if the target year is itself over the ceiling.
     */
    protected const SCOPE_TOO_LARGE_REDIRECT = 'All available fiscal years is too large to display, so FY :year has been selected. If that year is also too large, choose another fiscal year or contact IT.';

    /** Export refusals say plainly that NO FILE was written. */
    protected const EXPORT_SCOPE_TOO_LARGE = 'No file was created: all available fiscal years is too large to export. FY :year has been selected — export that year instead.';

    protected const EXPORT_SCOPE_TOO_LARGE_SINGLE_YEAR = 'No file was created: this fiscal year has too many requisition lines to export. Choose another fiscal year, or contact IT.';

    public function index(Request $request): Response|RedirectResponse
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

        // All-years is too large AND there is a year to fall back to: make the
        // URL canonical rather than silently showing a narrower scope than it
        // claims. Only this branch redirects, and only from the all-years path,
        // so the redirect target (a single year) can never redirect again.
        if ($this->shouldRedirectToSuggestedYear($r)) {
            return redirect()
                ->route($this->routeName(), $this->redirectQuery($request, $r['suggestedYear']))
                // INTERPOLATED — the constant carries a :year placeholder.
                ->with('warning', str_replace(
                    ':year', (string) $r['suggestedYear'], self::SCOPE_TOO_LARGE_REDIRECT,
                ));
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
            // The scope guard. BOTH are sent on every path — success, refused
            // and outage — so the three prop sets stay key-for-key identical;
            // a prop one path omits is a Vue error on top of whatever else
            // went wrong. The component gates every QUANTITY it renders on
            // !scopeRefused: a refusal means "we did not count this", which is
            // not "we counted zero".
            'scopeRefused' => $r['scopeRefused'],
            'scopeRefusedMessage' => $r['scopeRefusedMessage'],
        ]);
    }

    /**
     * Pure: no DB, no container, no request. Unit-tested offline in
     * Tests\Unit\RequisitionScopeDecisionTest — this is the one decision in the
     * guard that must not depend on a reachable SQL Server to be covered.
     *
     * @param  array<string,mixed>  $r
     */
    protected function shouldRedirectToSuggestedYear(array $r): bool
    {
        return $r['scopeRefused']
            && $r['activeFiscalYear'] === null      // we were on all-years
            && $r['suggestedYear'] !== null;        // and there is somewhere to go
    }

    /**
     * Carry the user's requested categoricals to the narrower year.
     *
     * These are REQUESTED, not "surviving": the refusal returns from resolve()
     * before the six validFilter() calls, because validation needs option lists
     * and option lists need a row set we deliberately did not materialise. Only
     * is_string values pass (so ?department[]=x cannot propagate), and the
     * redirected request validates them like any other — a value valid across
     * all years but absent from this one is dropped there, with the usual
     * visible reset.
     *
     * @return array<string,string>
     */
    private function redirectQuery(Request $request, int $year): array
    {
        $carried = array_filter(
            $request->only('cluster', 'institution', 'department', 'account', 'vendor', 'status'),
            fn ($v) => is_string($v) && $v !== '',
        );

        return $carried + ['fy' => (string) $year];
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

        // Never stream a truncated file. A CSV holding 25,000 of 93,336 rows
        // carries no row count, no warning and no scrollbar — it reads as the
        // complete answer, and would be reconciled against the ledger and found
        // wrong by someone with no way to see why. See routingupdate.md §6.6.
        //
        // TWO EXPLICIT BRANCHES, never `$year ?? 0`. suggestedYear is
        // deliberately null when a year was already selected, and `?? 0` would
        // redirect to ?fy=0 — an invalid year that validFilter() drops, so
        // index() would read it as "all years" and redirect AGAIN to the newest
        // year, moving the user off the year they asked about.
        //
        // Both branches go STRAIGHT to a concrete year rather than through
        // exportRedirect(), which replays $request->query(): on the all-years
        // path that would hand index() a yearless URL, earn a second redirect,
        // and leave the user reading a message about display selection that
        // never says no file was produced.
        if ($r['scopeRefused']) {
            // A SELECTED year was too large. Keep that year — the user's
            // context is the thing to preserve, and there is no better year to
            // offer them. Branching on activeFiscalYear rather than on
            // suggestedYear being null is what makes `(int)` below provably a
            // real four-digit year.
            if ($r['activeFiscalYear'] !== null) {
                return redirect()
                    ->route($this->routeName(), $this->redirectQuery($request, (int) $r['activeFiscalYear']))
                    ->with('warning', self::EXPORT_SCOPE_TOO_LARGE_SINGLE_YEAR);
            }

            if ($r['suggestedYear'] !== null) {
                // All-years was too large. Land on the suggested year and say so.
                return redirect()
                    ->route($this->routeName(), $this->redirectQuery($request, $r['suggestedYear']))
                    ->with('warning', str_replace(
                        ':year', (string) $r['suggestedYear'], self::EXPORT_SCOPE_TOO_LARGE,
                    ));
            }

            // All-years refused with NO eligible year to offer. Unreachable as
            // built — with no eligible years $scopeYears is [], which compiles
            // to WHERE 0 = 1, and zero rows cannot exceed a ceiling. Handled
            // anyway so that a future change to how the scope is built cannot
            // fall through to an uninterpolated message or a ?fy=0 redirect.
            return $this->exportRedirect($request, $this->routeName(), self::SCOPE_TOO_LARGE);
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
     * muting a row, not data. So is the snapshot timestamp: it is the same
     * value on every row of any one file, which is padding rather than
     * information — and since the year became optional the file can span many
     * fiscal years, so a per-row stamp would be no more informative. Both
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
     * view aliases ActBalance to it — the unshipped balance, SIGNED and not
     * floored at zero since the Access-parity change, so an over-received line
     * is negative), and Extended Cost is already net of receipts and likewise
     * signed. Recomputing either in PHP is what would break Phase 2's
     * reconciliation guarantee silently.
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
     *               accounts:array, vendors:array, statuses:array,
     *               scopeRefused:bool, scopeRefusedMessage:?string,
     *               suggestedYear:?int}
     */
    private function resolve(Request $request): array
    {
        $username = $request->user()->username;
        $filters = $request->only('cluster', 'institution', 'department', 'account', 'vendor', 'status', 'fy');

        $yearData = $this->availableYears($username);
        $years = collect($yearData['years']);          // ELIGIBLE years, NEWEST FIRST

        // FISCAL YEAR IS AN OPTIONAL FILTER, defaulting to every eligible year.
        //
        // Deliberately NOT ResolvesFiscalYear::resolveFiscalYear(): that helper
        // can never return null — it substitutes the current FY, then the
        // latest year with data — which is exactly the forcing this page
        // dropped. It stays untouched for the four pages that keep the hero and
        // genuinely want a year always set.
        $dropped = [];
        $requestedYear = $this->validFilter($request, 'fy', $years->all(), $dropped);
        $activeFiscalYear = $requestedYear === null ? null : (int) $requestedYear;
        $filters['fy'] = $activeFiscalYear;

        // THE ELIGIBLE-YEAR SET, ALWAYS APPLIED. "All" means every year THIS
        // ROUTE's detail shares with the ledger — never every year the snapshot
        // holds, and not the ledger's own 13-year boundary either (Routing has
        // only 3 eligible years). Measured 2026-10-01, skipping this bound
        // leaked 49 FY2011-13 rows / TTD 75,829.66 into the Encumbered page,
        // breaking reconciliation by exactly that: those years have no summary
        // row to reconcile against.
        //
        // An EMPTY list must return zero rows, not all rows. whereIn(…, [])
        // generates WHERE 0 = 1, which is correct — a user with no eligible
        // years has no eligible detail. This is the one place "no filter" must
        // not mean "everything".
        $scopeYears = $activeFiscalYear !== null
            ? [(string) $activeFiscalYear]
            : $years->map(fn ($y) => (string) $y)->all();

        $hasAccess = $this->userHasLedgerAccess($username);
        $snapshot = $this->snapshotFreshness();

        // The read is BOUNDED — $rows is never larger than ceiling + 1, whatever
        // the scope. See fetchBoundedRows().
        [$rows, $scopeRefused] = $this->fetchBoundedRows($username, $scopeYears);

        if ($scopeRefused) {
            // Returns EARLY, before the six validFilter() calls below — which is
            // why the categoricals come back raw and droppedFilters is empty:
            // validation needs option lists, and option lists need a row set we
            // have deliberately not materialised.
            return $this->refusedResolution(
                $request, $years, $yearData, $hasAccess, $snapshot, $activeFiscalYear,
            );
        }

        // ── Filter option lists (scoped to the rows in scope — one fiscal year,
        //    or every eligible year) ──────────────────────────────────────────
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
        // Only honour a selection that is a valid option in the rows in scope,
        // so a stale filter carried across an FY switch never silently empties
        // the table. A non-empty invalid value lands in $dropped: index()
        // ignores it, export() refuses on it. ($dropped is declared above, with
        // the fiscal year, because `fy` goes through the same gate.)
        $filtered = $rows;

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
            'scopeRefused' => false,
            'scopeRefusedMessage' => null,
            // Drives index()'s redirect decision only. Not an Inertia prop —
            // which is why the rendered prop set is 17 keys and not 18.
            'suggestedYear' => null,
        ];
    }

    /**
     * resolve()'s return when the scope exceeds the row ceiling.
     *
     * rows is EMPTY and no total is computed from the truncated fetch — an
     * arbitrary 25,000 of 93,336 rows is not a measurement of anything. The
     * presentation layer gates every quantity on !scopeRefused, so the zeros
     * requisitionTotals() produces from this empty collection are never
     * rendered: that is the whole point of the state. "We did not count this"
     * must not be shown as "we counted zero", the same rule the outage path's
     * hasAccess => true follows.
     *
     * @param  Collection<int,string>  $years
     * @param  array{years:array<int,string>,unsummarised:array<int,string>}  $yearData
     * @param  array{refreshedAt:string|null,age:string|null}  $snapshot
     * @return array<string,mixed>
     */
    private function refusedResolution(
        Request $request,
        Collection $years,
        array $yearData,
        bool $hasAccess,
        array $snapshot,
        ?int $requestedYear,
    ): array {
        // Which message depends on whether the user can still act. A selected
        // year that is too large has no remedy on this page; all-years does.
        $singleYear = $requestedYear !== null;

        return [
            'rows' => collect(),                       // never the truncated fetch
            // Raw requested categoricals, echoed back. The <select>s will show
            // them as unmatched and therefore blank, which is acceptable
            // BECAUSE those selects are disabled in this state — the only live
            // control is Fiscal Year. Echoing them preserves them for the
            // redirect and for the user's next action rather than silently
            // discarding what they asked for.
            'filters' => $request->only('cluster', 'institution', 'department', 'account', 'vendor', 'status')
                + ['fy' => $requestedYear],
            'droppedFilters' => [],                    // categorical validation never ran
            'activeFiscalYear' => $requestedYear,
            // POPULATED, and that is load-bearing: `years` comes from
            // availableYears(), not from the fetched rows, so the Fiscal Year
            // dropdown still works while every other option list is empty.
            // It is the only recovery, so it has to be reachable.
            'years' => $years->all(),
            'unsummarisedYears' => $yearData['unsummarised'],
            'clusters' => [],
            'institutions' => [],
            'departments' => [],
            'accounts' => [],
            'vendors' => [],
            'statuses' => [],
            'hasAccess' => $hasAccess,
            'snapshot' => $snapshot,
            'scopeRefused' => true,
            'scopeRefusedMessage' => $singleYear
                ? self::SCOPE_TOO_LARGE_SINGLE_YEAR
                : self::SCOPE_TOO_LARGE,
            // Null when a year was already selected — which is exactly what
            // stops shouldRedirectToSuggestedYear() from looping.
            //
            // The explicit isEmpty() check matters: (int) $years->first() is 0
            // on an empty collection, and 0 is not a fiscal year — it would
            // make the redirect fire and land on ?fy=0.
            'suggestedYear' => ($singleYear || $years->isEmpty()) ? null : (int) $years->first(),
        ];
    }

    // =========================================================================
    // Reads
    // =========================================================================

    /**
     * Fetch the scope with a hard row bound.
     *
     * The only reliable guard is one that cannot be outrun by the thing it
     * guards. A threshold checked after get()->map() runs after the allocation
     * it polices, and an out-of-memory kills the request first. A COUNT(*)
     * pre-flight predicts the allocation then performs it separately — two
     * statements, so it can be raced (the access mapping is a LIVE view), and
     * an earlier draft's version was bypassed entirely by ?fy=.
     *
     * Fetching ceiling + 1 BOUNDS it instead: PHP never materialises more than
     * that for any scope, and getting ceiling + 1 rows back IS the too-large
     * signal. Measured 2026-10-01 against the 93,336-row worst case through the
     * full pipeline: 25,001 rows, 172 MB peak, 1.29 s — against 558 MB
     * unbounded.
     *
     * Because the bound applies to EVERY call, a selected year over the ceiling
     * and the redirect's target year are both covered. No double logging: the
     * guard lives in resolve(), which index() and export() each call once.
     *
     * @param  array<int,string>  $scopeYears
     * @return array{0:Collection<int,array<string,mixed>>,1:bool}
     */
    private function fetchBoundedRows(string $username, array $scopeYears): array
    {
        $t = $this->scopeThresholds();

        $rows = $this->detailRows($username, $scopeYears, $t->ceiling > 0 ? $t->ceiling + 1 : null);

        $refused = $t->ceiling > 0 && $rows->count() > $t->ceiling;

        if ($refused) {
            Log::warning('Requisition detail scope exceeds the row ceiling; refusing.', [
                'page' => $this->routeName(),
                'username' => $username,
                'years' => $scopeYears,
                'ceiling' => $t->ceiling,
            ]);
        } elseif ($t->warnAt > 0 && $rows->count() > $t->warnAt) {
            Log::warning('Requisition detail working set is large; see routingupdate.md §6.', [
                'page' => $this->routeName(),
                'username' => $username,
                'rows' => $rows->count(),
                'years' => count($scopeYears),
            ]);
        }

        return [$rows, $refused];
    }

    /** Validated and clamped — 0 disables the guard, garbage falls back to the default. */
    private function scopeThresholds(): RequisitionScopeThresholds
    {
        return RequisitionScopeThresholds::fromConfig(
            config('ledger.requisition.row_ceiling'),
            config('ledger.requisition.row_warn'),
        );
    }

    /**
     * The fiscal years this page offers, and the ones deliberately withheld.
     *
     * THE OPTION LIST IS BOUNDED TO YEARS THE LEDGER ALSO HAS, and so is the
     * all-years query scope — see the whereIn() in resolve(). Measured on production
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

        // NEWEST FIRST, matching the table's FinancialYear DESC order and
        // putting the year people actually want at the top of the select. The
        // source query is orderBy('FinancialYear') ascending and
        // array_intersect preserves that order, so without the reverse the
        // dropdown read FY2014…FY2026 while the table read newest-first.
        //
        // Every consumer compares these as SETS (reconciliation, the
        // withheld-years note, the tests), so the order is presentation only —
        // but it is also what makes years->first() the NEWEST year, which the
        // suggested-year redirect depends on.
        return [
            'years' => array_values(array_reverse(array_intersect($detailYears, $ledgerYears))),
            'unsummarised' => array_values(array_reverse(array_diff($detailYears, $ledgerYears))),
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
     * Every detail line for the user, the years in scope and the status set, as
     * plain arrays.
     *
     * UNCACHED, like every other table query in this app — only the dropdown
     * lists are cached. Ordered so a reader scanning by requisition sees its
     * lines together.
     *
     * $scopeYears is bound UNCONDITIONALLY. An empty array compiles to
     * WHERE 0 = 1, which is the correct answer for a user with no eligible
     * years — see resolve().
     *
     * $limit is the bounded fetch's ceiling + 1; null disables the bound, which
     * only happens when the guard is explicitly switched off in config.
     *
     * FinanceRequisition::scopeForYear() is no longer used by these two pages
     * (the scope is a whereIn now). It stays on the shared model for any future
     * single-year reader.
     *
     * @param  array<int,string>  $scopeYears
     * @return Collection<int,array<string,mixed>>
     */
    private function detailRows(string $username, array $scopeYears, ?int $limit = null): Collection
    {
        $query = FinanceRequisition::forUser($username)
            ->whereIn('FinancialYear', $scopeYears)
            ->withStatuses($this->statuses())
            ->select(self::COLUMNS)
            // FinancialYear DESC is the only key that MOVES A ROW today, and
            // PONumber is appended as a provably inert tie-break.
            //
            // The reference query (sql/Phase2RequisitionDetail_*.sql and the
            // finance team's drafts in sql/source/) has NO ORDER BY AT ALL, so
            // Department, RequisitionNumber, LineNbr are the application's own
            // invention and are kept exactly as they are. Within one selected
            // year FinancialYear is constant, so single-year output is
            // byte-for-byte what it was before the year became optional; with
            // All selected it groups years into contiguous blocks instead of
            // interleaving them.
            //
            // Measured 2026-10-01 (GROUP BY, not CONCAT — 685 rows have a NULL
            // Department and T-SQL CONCAT renders NULL as ''):
            // (FinancialYear, Department, RequisitionNumber, LineNbr) has 0
            // tied groups in 108,435 rows, so it is already a total order and a
            // fifth key can never be consulted. PONumber therefore reorders
            // nothing today, while guarding the one further tie the declared
            // snapshot grain permits without relying on a manual re-check. It
            // goes AFTER LineNbr, never before: before it, it would reorder the
            // lines of a requisition spanning two POs.
            //
            // That makes the sort key a SUPERSET of the key the refresh proc's
            // DuplicateGrainRows already watches (FinancialYear,
            // RequisitionNumber, PONumber, LineNbr) — plus Department — and a
            // superset of a unique key is unique. So DuplicateGrainRows = 0
            // proves pagination is stable. See routingupdate.md §3.1.
            ->orderByDesc('FinancialYear')
            ->orderBy('Department')
            ->orderBy('RequisitionNumber')
            ->orderBy('LineNbr')
            ->orderBy('PONumber');

        if ($limit !== null) {
            $query->limit($limit);
        }

        return $query->get()
            ->map(fn ($row) => $this->deriveRequisitionRow((array) $row->getAttributes(), self::COLUMNS));
    }

    /**
     * When the detail was last built, and whether that is a PROBLEM.
     *
     * Phase 2 traded live data for reconciliation — a requisition raised at
     * 09:00 does not appear until the next refresh. The trade is only honest if
     * the page says so, so this is rendered on both pages rather than left
     * implicit.
     *
     * Since 2026-10-02 it also carries a STATE, because "a night old" and "the
     * nightly job stopped running three days ago" look identical in a relative
     * age and mean completely different things. A stopped Agent job produces no
     * error of any kind — pages keep loading fast and the figures simply stop
     * moving — and with no monitoring configured on production this strip is
     * currently the only place a user could notice.
     *
     * @return array{refreshedAt:string|null,age:string|null,state:string,ageHours:float|null}
     */
    private function snapshotFreshness(): array
    {
        $refreshedAt = $this->requisitionRefreshedAt();
        $state = $this->snapshotState(
            $refreshedAt,
            $this->requisitionLatestOutcome(),
            (int) config('ledger.requisition.max_age_hours'),
        );

        if ($refreshedAt === null) {
            return ['refreshedAt' => null, 'age' => null, 'state' => $state, 'ageHours' => null];
        }

        $moment = Carbon::parse($refreshedAt);

        return [
            'refreshedAt' => $moment->toIso8601String(),
            // Server-side, because the DB server writes RefreshedAt with
            // SYSDATETIME() and a browser clock would be a third one.
            'age' => $moment->diffForHumans(),
            'state' => $state,
            // Operand order matters: Carbon 3's diffInHours is SIGNED and
            // returns ($other - $this), so a past refresh must read
            // refreshedAt->diffInHours(now()) to come out positive.
            'ageHours' => round($moment->diffInHours(Carbon::now()), 1),
        ];
    }

    /**
     * Pure. Unit-tested offline in Tests\Unit\RequisitionScopeDecisionTest.
     *
     * FOUR states, never conflated — the same discipline as the hasAccess trio:
     *
     *   unknown  the probe could not run, or the snapshot has never built. We
     *            do NOT know, so we must not say "stale": telling someone the
     *            nightly job has failed when the metadata query merely timed
     *            out sends them to chase the wrong thing.
     *   failed   the NEWEST run aborted. The previous snapshot still stands and
     *            still reconciles, so the figures are usable — but they will
     *            not move again until someone looks. Invisible to the
     *            timestamp, because that reads only OK rows.
     *   stale    the last GOOD run is older than the configured limit. The
     *            threshold is shared with `ledger:status` through config, so the
     *            page cannot reassure a user the health check is alerting on.
     *   ok       a night old, which is the DESIGNED state and not a fault.
     *
     * `failed` is checked BEFORE `stale` because it is the more specific and
     * more actionable fact: a run that aborted tonight is not yet 36h stale,
     * and reporting only the age would hide it until tomorrow.
     *
     * $maxAgeHours is PASSED IN rather than read from config() here, the same
     * way RequisitionScopeThresholds takes its values: it keeps this method
     * container-free, which is what lets the offline unit suite exercise every
     * state with no application booted. 0 disables the age check alone.
     */
    protected function snapshotState(?string $refreshedAt, ?string $latestOutcome, int $maxAgeHours): string
    {
        if ($refreshedAt === null) {
            return 'unknown';
        }

        if ($latestOutcome !== null && strtoupper($latestOutcome) !== 'OK') {
            return 'failed';
        }

        if ($maxAgeHours > 0 && Carbon::parse($refreshedAt)->diffInHours(Carbon::now()) > $maxAgeHours) {
            return 'stale';
        }

        return 'ok';
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

        // Fall back to ALL FISCAL YEARS, never to the requested value.
        //
        // The availability query failed, so the eligible-year set is UNKNOWN and
        // no requested year can be validated against it. Echoing back a
        // four-digit string would let ?fy=9999 paint "FY 9999 · Oct 9998 – Sep
        // 9999" over an empty table. Same principle as hasAccess => true below:
        // on an outage, assert nothing you cannot establish.
        $filters['fy'] = null;

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
            // 'unknown', not 'stale': the probe could not run, so we do not
            // know. Same shape as the success path, key for key.
            'snapshot' => ['refreshedAt' => null, 'age' => null, 'state' => 'unknown', 'ageHours' => null],
            'unsummarisedYears' => [],
            // False, not true: nothing was refused — the source was unreachable,
            // which is a different state with its own copy. Both keys are sent
            // so this path's prop set matches the other two key for key.
            'scopeRefused' => false,
            'scopeRefusedMessage' => null,
        ]);
    }
}
