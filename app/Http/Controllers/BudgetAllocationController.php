<?php

namespace App\Http\Controllers;

use App\Concerns\ResolvesFiscalYear;
use App\Models\BudgetAllocation;
use Illuminate\Http\Request;
use Illuminate\Pagination\LengthAwarePaginator;
use Illuminate\Support\Facades\Cache;
use Inertia\Inertia;
use Inertia\Response;

class BudgetAllocationController extends Controller
{
    use ResolvesFiscalYear;

    public function index(Request $request): Response
    {
        $username = $request->user()->username;
        $filters = $request->only('cluster', 'institution', 'responsibility', 'department', 'account', 'fy');

        $base = fn () => BudgetAllocation::forUser($username);

        // Filter dropdown lists depend only on (user, FY) and the source data is
        // read-only, so they are cached on a dedicated store (see config/budget.php).
        $cache = Cache::store(config('budget.cache.store'));
        $cacheTtl = config('budget.cache.minutes') * 60;

        try {
            // ── Available fiscal years (all years — drives the FY navigator) ──
            // Cached as a plain array; wrapped in collect() for the FY helpers.
            $years = collect($cache->remember(
                "budget-allocations:years:{$username}",
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
            // pass (see self::FILTER_CACHE_TTL).
            $fyBase = function () use ($base, $activeFiscalYear) {
                $query = $base();
                if ($activeFiscalYear !== null) {
                    $query->where('FinancialYear', (string) $activeFiscalYear);
                }

                return $query;
            };

            $options = $cache->remember(
                "budget-allocations:options:{$username}:{$activeFiscalYear}",
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
            $query = $fyBase();

            $filters['cluster'] = ($v = $request->input('cluster')) && in_array($v, $clusters, true)
                ? tap($v, fn ($v) => $query->where('ClusterName', $v)) : null;

            $filters['institution'] = ($v = $request->input('institution')) && in_array($v, array_column($institutions, 'InstitutionName'), true)
                ? tap($v, fn ($v) => $query->where('InstitutionName', $v)) : null;

            $filters['responsibility'] = ($v = $request->input('responsibility')) && in_array($v, $responsibilities, true)
                ? tap($v, fn ($v) => $query->where('ResponsibilityName', $v)) : null;

            $filters['department'] = ($v = $request->input('department')) && in_array($v, $departments, true)
                ? tap($v, fn ($v) => $query->where('DepartmentName', $v)) : null;

            $filters['account'] = ($v = $request->input('account')) && in_array($v, array_column($accounts, 'AccountNumber'), true)
                ? tap($v, fn ($v) => $query->where('AccountNumber', $v)) : null;

            // ── Stats (full filtered set, before pagination) ──────────────────
            // The single largest line drives the "Largest Allocation" KPI; its
            // account description is shown as the card's sub-label.
            $largest = (clone $query)->orderByDesc('TotalAllocation')->first();

            $stats = [
                'total' => (clone $query)->count(),
                'totalAllocation' => (float) (clone $query)->sum('TotalAllocation'),
                'largest' => [
                    'amount' => (float) ($largest->TotalAllocation ?? 0),
                    'label' => $largest->AccountDescription ?? null,
                ],
            ];

            // ── Paginated results ─────────────────────────────────────────────
            $allocations = $query
                ->orderBy('FinancialYear')
                ->orderBy('ClusterName')
                ->orderBy('InstitutionName')
                ->orderBy('DepartmentName')
                ->orderBy('AccountNumber')
                ->paginate(25)
                ->withQueryString();

        } catch (\Throwable $e) {
            session()->flash('warning', 'Could not connect to the financial data source. Please try again later.');

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
            ]);
        }

        return Inertia::render('Budget/All Budget Allocations', [
            'allocations' => $allocations,
            'clusters' => $clusters,
            'institutions' => $institutions,
            'responsibilities' => $responsibilities,
            'departments' => $departments,
            'accounts' => $accounts,
            'years' => $years,
            'stats' => $stats,
            'filters' => $filters,
            'activeFiscalYear' => $activeFiscalYear,
            'currentFiscalYear' => $currentFiscalYear,
            'fyNav' => $fyNav,
        ]);
    }
}
