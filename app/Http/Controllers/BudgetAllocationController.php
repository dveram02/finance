<?php

namespace App\Http\Controllers;

use App\Concerns\ExportsReports;
use App\Concerns\ResolvesFiscalYear;
use App\Concerns\ResolvesLedgerAccess;
use App\Concerns\VersionsLedgerCache;
use App\Models\BudgetAllocation;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Illuminate\Pagination\LengthAwarePaginator;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Log;
use Inertia\Inertia;
use Inertia\Response;
use Symfony\Component\HttpFoundation\StreamedResponse;

class BudgetAllocationController extends Controller
{
    use ExportsReports;
    use ResolvesFiscalYear;
    use ResolvesLedgerAccess;
    use VersionsLedgerCache;

    /** Export column headings, in order. This order is an API contract. */
    private const EXPORT_HEADINGS = [
        'Financial Year', 'Cluster', 'Institution', 'Responsibility', 'Department',
        'Account Description', 'Account Number', 'Total Allocation',
    ];

    public function index(Request $request): Response
    {
        // Held outside the try so the outage path can still echo back what the
        // user asked for.
        $filters = $request->only('cluster', 'institution', 'responsibility', 'department', 'account', 'fy');

        try {
            $r = $this->resolve($request);
        } catch (\Throwable $e) {
            return $this->unavailable($request, $filters, $e);
        }

        $query = $r['query'];

        // ── Stats (full filtered set, before pagination) ──────────────────────
        // The single largest line drives the "Largest Allocation" KPI; its
        // account description is shown as the card's sub-label. Ordering is
        // applied to CLONES here, never to $query itself — an ordered $query
        // would put orderByDesc('TotalAllocation') second and silently return
        // the wrong "largest".
        $largest = (clone $query)->orderByDesc('TotalAllocation')->first();

        $stats = [
            'total' => (clone $query)->count(),
            'totalAllocation' => (float) (clone $query)->sum('TotalAllocation'),
            'largest' => [
                'amount' => (float) ($largest->TotalAllocation ?? 0),
                'label' => $largest->AccountDescription ?? null,
            ],
        ];

        return Inertia::render('Budget/All Budget Allocations', [
            'allocations' => $this->applyOrder(clone $query)->paginate(25)->withQueryString(),
            'hasAccess' => $r['hasAccess'],
            'clusters' => $r['clusters'],
            'institutions' => $r['institutions'],
            'responsibilities' => $r['responsibilities'],
            'departments' => $r['departments'],
            'accounts' => $r['accounts'],
            'years' => $r['years'],
            'stats' => $stats,
            'filters' => $r['filters'],
            'activeFiscalYear' => $r['activeFiscalYear'],
            'currentFiscalYear' => $r['currentFiscalYear'],
            'fyNav' => $r['fyNav'],
        ]);
    }

    // =========================================================================
    // Export
    // =========================================================================

    /**
     * The whole filtered set as CSV — never just the visible page.
     *
     * Shares resolve() with index(), so the file and the screen cannot report
     * different rows. See App\Concerns\ExportsReports for why a stale filter is
     * refused here but silently discarded on the page.
     */
    public function export(Request $request): StreamedResponse|RedirectResponse
    {
        try {
            $r = $this->resolve($request);
        } catch (\Throwable $e) {
            Log::error('Budget allocation export failed.', [
                'username' => $request->user()->username,
                'fy' => $request->input('fy'),
                'exception' => $e->getMessage(),
            ]);

            return $this->exportRedirect($request, 'budget-allocations.index', self::EXPORT_UNAVAILABLE);
        }

        if (! $r['hasAccess']) {
            return $this->exportRedirect($request, 'budget-allocations.index', self::EXPORT_NO_ACCESS);
        }

        if ($r['droppedFilters'] !== []) {
            return $this->exportRedirect($request, 'budget-allocations.index', self::EXPORT_STALE_FILTER);
        }

        // MATERIALISED, not cursor()d. A cursor holds a live database connection
        // open while the response streams, so a dropped connection truncates a
        // file whose headers are already committed. Reading it now moves that
        // failure back to where it can still become a redirect, and costs one
        // query instead of a separate count(). The set is small: this view is
        // FY2025-onward, Allocation <> 0 and user-scoped.
        $rows = $this->applyOrder($r['query'])->get();

        if ($rows->isEmpty()) {
            return $this->exportRedirect($request, 'budget-allocations.index', self::EXPORT_NO_ROWS);
        }

        Log::info('CSV export started.', [
            'page' => 'budget-allocations',
            'username' => $request->user()->username,
            'fy' => $r['activeFiscalYear'],
            'filters' => array_filter($r['filters']),
            'rows' => $rows->count(),
        ]);

        return $this->streamCsv(
            $this->csvFilename('budget-allocations', $r['activeFiscalYear']),
            self::EXPORT_HEADINGS,
            fn () => $this->exportRows($rows),
            ['page' => 'budget-allocations', 'username' => $request->user()->username],
        );
    }

    /**
     * @param  Collection<int,BudgetAllocation>  $rows
     * @return \Generator<int,array<int,string>>
     */
    private function exportRows($rows): \Generator
    {
        foreach ($rows as $row) {
            yield [
                $this->csvText($row->FinancialYear),
                $this->csvText($row->ClusterName),
                $this->csvText($row->InstitutionName),
                $this->csvText($row->ResponsibilityName),
                $this->csvText($row->DepartmentName),
                $this->csvText($row->AccountDescription),
                $this->csvText($row->AccountNumber),
                $this->csvMoney($row->TotalAllocation),
            ];
        }
    }

    // =========================================================================
    // Shared resolution
    // =========================================================================

    /**
     * Everything index() and export() both need.
     *
     * A pure lift of what used to be inline in index(), extracted so the two
     * cannot drift: a filter is only honoured when it is a valid option in the
     * active fiscal year, and that validation depends on the cached option
     * lists built just above it. Duplicating the block into export() would have
     * guaranteed they diverged.
     *
     * Returns the filtered but UNORDERED query — ordering is applied per caller
     * via applyOrder(), because index()'s stats clone the query and append
     * their own ordering.
     *
     * Throws on any SQL failure; the caller decides whether that renders an
     * empty page or redirects.
     *
     * @return array{query:Builder, filters:array<string,mixed>, droppedFilters:array<int,string>,
     *               activeFiscalYear:?int, currentFiscalYear:int, years:array<int,string>,
     *               fyNav:array{prev:?int,next:?int}, hasAccess:bool, clusters:array,
     *               institutions:array, responsibilities:array, departments:array, accounts:array}
     */
    private function resolve(Request $request): array
    {
        $username = $request->user()->username;
        $filters = $request->only('cluster', 'institution', 'responsibility', 'department', 'account', 'fy');

        $base = fn () => BudgetAllocation::forUser($username);

        // Filter dropdown lists depend only on (user, FY) and the source data is
        // read-only, so they are cached on a dedicated store (see config/budget.php).
        $cache = Cache::store(config('budget.cache.store'));
        $cacheTtl = config('budget.cache.minutes') * 60;

        $hasAccess = $this->userHasLedgerAccess($username);

        // ── Available fiscal years (all years — drives the FY navigator) ──
        // Cached as a plain array; wrapped in collect() for the FY helpers.
        $years = collect($cache->remember(
            $this->ledgerCacheKey("budget-allocations:years:{$username}"),
            $cacheTtl,
            fn () => $base()
                ->select('FinancialYear')
                ->distinct()
                ->orderBy('FinancialYear')
                ->pluck('FinancialYear')
                ->filter()
                ->values()
                ->all()
        ));

        // ── Resolve the active fiscal year ────────────────────────────────
        $currentFiscalYear = $this->currentFiscalYear();
        $activeFiscalYear = $this->resolveFiscalYear($request->input('fy'), $years, $currentFiscalYear);
        $fyNav = $this->fiscalYearNav($activeFiscalYear, $years);
        $filters['fy'] = $activeFiscalYear;

        // ── Filter option lists (scoped to the active fiscal year) ────────
        // The results table is always locked to a single fiscal year, so the
        // dropdowns must offer only values that exist in that year — otherwise
        // a user can pick a value that returns zero rows. The lists depend
        // only on (user, FY), so they are cached and resolved together in one
        // pass.
        $fyBase = function () use ($base, $activeFiscalYear) {
            $query = $base();
            if ($activeFiscalYear !== null) {
                $query->where('FinancialYear', (string) $activeFiscalYear);
            }

            return $query;
        };

        $options = $cache->remember(
            $this->ledgerCacheKey("budget-allocations:options:{$username}:{$activeFiscalYear}"),
            $cacheTtl,
            fn () => [
                'clusters' => $fyBase()
                    ->select('ClusterName')
                    ->distinct()
                    ->orderBy('ClusterName')
                    ->pluck('ClusterName')
                    ->filter()
                    ->values()
                    ->all(),

                // Keyed on cluster+institution so an institution that appears
                // under more than one cluster survives the client-side cascade.
                'institutions' => $fyBase()
                    ->select('ClusterName', 'InstitutionName')
                    ->distinct()
                    ->orderBy('InstitutionName')
                    ->get()
                    ->unique(fn ($i) => $i->ClusterName.'|'.$i->InstitutionName)
                    ->map(fn ($i) => [
                        'ClusterName' => $i->ClusterName,
                        'InstitutionName' => $i->InstitutionName,
                    ])
                    ->values()
                    ->all(),

                'responsibilities' => $fyBase()
                    ->select('ResponsibilityName')
                    ->distinct()
                    ->orderBy('ResponsibilityName')
                    ->pluck('ResponsibilityName')
                    ->filter()
                    ->values()
                    ->all(),

                'departments' => $fyBase()
                    ->select('DepartmentName')
                    ->distinct()
                    ->orderBy('DepartmentName')
                    ->pluck('DepartmentName')
                    ->filter()
                    ->values()
                    ->all(),

                'accounts' => $fyBase()
                    ->select('AccountNumber', 'AccountDescription')
                    ->distinct()
                    ->orderBy('AccountDescription')
                    ->get()
                    ->unique('AccountNumber')
                    ->map(fn ($a) => [
                        'AccountNumber' => $a->AccountNumber,
                        'AccountDescription' => $a->AccountDescription,
                    ])
                    ->values()
                    ->all(),
            ]
        );

        ['clusters' => $clusters, 'institutions' => $institutions,
            'responsibilities' => $responsibilities, 'departments' => $departments,
            'accounts' => $accounts] = $options;

        // ── Filtered query ────────────────────────────────────────────────
        // Only apply a selection if it is a valid option in the active fiscal
        // year, so the table never silently filters on a value the user can no
        // longer see selected (e.g. a stale filter carried across an FY switch).
        // A non-empty invalid value lands in $dropped: index() ignores it, and
        // export() refuses on it.
        $query = $fyBase();
        $dropped = [];

        $filters['cluster'] = $this->validFilter($request, 'cluster', $clusters, $dropped);
        if ($filters['cluster']) {
            $query->where('ClusterName', $filters['cluster']);
        }

        $filters['institution'] = $this->validFilter($request, 'institution', array_column($institutions, 'InstitutionName'), $dropped);
        if ($filters['institution']) {
            $query->where('InstitutionName', $filters['institution']);
        }

        $filters['responsibility'] = $this->validFilter($request, 'responsibility', $responsibilities, $dropped);
        if ($filters['responsibility']) {
            $query->where('ResponsibilityName', $filters['responsibility']);
        }

        $filters['department'] = $this->validFilter($request, 'department', $departments, $dropped);
        if ($filters['department']) {
            $query->where('DepartmentName', $filters['department']);
        }

        $filters['account'] = $this->validFilter($request, 'account', array_column($accounts, 'AccountNumber'), $dropped);
        if ($filters['account']) {
            $query->where('AccountNumber', $filters['account']);
        }

        return [
            'query' => $query,
            'filters' => $filters,
            'droppedFilters' => $dropped,
            'activeFiscalYear' => $activeFiscalYear,
            'currentFiscalYear' => $currentFiscalYear,
            'years' => $years->all(),
            'fyNav' => $fyNav,
            'hasAccess' => $hasAccess,
            'clusters' => $clusters,
            'institutions' => $institutions,
            'responsibilities' => $responsibilities,
            'departments' => $departments,
            'accounts' => $accounts,
        ];
    }

    /**
     * The row order, single-sourced so the page and the CSV agree.
     */
    private function applyOrder(Builder $query): Builder
    {
        return $query
            ->orderBy('FinancialYear')
            ->orderBy('ClusterName')
            ->orderBy('InstitutionName')
            ->orderBy('DepartmentName')
            ->orderBy('AccountNumber');
    }

    /**
     * SQL Server is unreachable — render an explicitly EMPTY page, never a
     * zero-valued one. The prop set must match the success path key for key.
     */
    private function unavailable(Request $request, array $filters, \Throwable $e): Response
    {
        // The generic copy must not hide the cause; this catch fires on any
        // SQL failure, not just connectivity.
        Log::error('Budget allocation query failed.', [
            'username' => $request->user()->username,
            'fy' => $request->input('fy'),
            'exception' => $e->getMessage(),
        ]);

        session()->flash('warning', 'The financial data source is unavailable. Please try again later.');

        $currentFiscalYear = $this->currentFiscalYear();
        $filters['fy'] = $filters['fy'] ?? $currentFiscalYear;

        return Inertia::render('Budget/All Budget Allocations', [
            'allocations' => new LengthAwarePaginator([], 0, 25, 1, [
                'path' => $request->url(),
                'query' => $request->query(),
            ]),
            'clusters' => [],
            'institutions' => [],
            'responsibilities' => [],
            'departments' => [],
            'accounts' => [],
            'years' => [],
            'stats' => [
                'total' => 0,
                'totalAllocation' => 0,
                'largest' => ['amount' => 0, 'label' => null],
            ],
            'filters' => $filters,
            'activeFiscalYear' => $filters['fy'],
            'currentFiscalYear' => $currentFiscalYear,
            'fyNav' => ['prev' => null, 'next' => null],
            // True on an outage: the access probe could not run, so we do not
            // know, and must not tell the user they have no permissions.
            'hasAccess' => true,
        ]);
    }
}
