<?php

namespace App\Http\Controllers;

use App\Concerns\ResolvesFiscalYear;
use App\Models\MonthlyExpenditure;
use Illuminate\Http\Request;
use Illuminate\Pagination\LengthAwarePaginator;
use Illuminate\Support\Facades\Cache;
use Inertia\Inertia;
use Inertia\Response;

class MonthlyExpenditureController extends Controller
{
    use ResolvesFiscalYear;

    public function index(Request $request): Response
    {
        $username = $request->user()->username;
        $filters = $request->only('cluster', 'institution', 'responsibility', 'account', 'period', 'group', 'fy');

        $base = fn () => MonthlyExpenditure::forUser($username);

        // Filter dropdown lists depend only on (user, FY) and the source data is
        // read-only, so they are cached on a dedicated store (see config/expenditure.php).
        $cache = Cache::store(config('expenditure.cache.store'));
        $cacheTtl = config('expenditure.cache.minutes') * 60;

        try {
            // ── Available fiscal years (all years — drives the FY navigator) ──
            $years = collect($cache->remember(
                "monthly-expenditure:years:{$username}",
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
            // dropdowns must offer only values that exist in that year. The lists
            // depend only on (user, FY), so they are cached and resolved together.
            $fyBase = function () use ($base, $activeFiscalYear) {
                $query = $base();
                if ($activeFiscalYear !== null) {
                    $query->where('FinancialYear', (string) $activeFiscalYear);
                }

                return $query;
            };

            $options = $cache->remember(
                "monthly-expenditure:options:{$username}:{$activeFiscalYear}",
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
                        ->select('Responsibility')
                        ->distinct()
                        ->orderBy('Responsibility')
                        ->pluck('Responsibility')
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

                    // Ordered by PeriodID (fiscal-month order, not alphabetical).
                    'months' => $fyBase()
                        ->select('PeriodID', 'TRXPeriod')
                        ->distinct()
                        ->orderBy('PeriodID')
                        ->get()
                        ->unique('PeriodID')
                        ->map(fn ($m) => [
                            'PeriodID' => $m->PeriodID,
                            'TRXPeriod' => $m->TRXPeriod,
                        ])
                        ->values()
                        ->all(),

                    'mainGroups' => $fyBase()
                        ->select('MainGroup')
                        ->distinct()
                        ->orderBy('MainGroup')
                        ->pluck('MainGroup')
                        ->filter()
                        ->values()
                        ->all(),
                ]
            );

            ['clusters' => $clusters, 'institutions' => $institutions,
                'responsibilities' => $responsibilities, 'accounts' => $accounts,
                'months' => $months, 'mainGroups' => $mainGroups] = $options;

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
                ? tap($v, fn ($v) => $query->where('Responsibility', $v)) : null;

            $filters['account'] = ($v = $request->input('account')) && in_array($v, array_column($accounts, 'AccountNumber'), true)
                ? tap($v, fn ($v) => $query->where('AccountNumber', $v)) : null;

            $filters['period'] = ($v = $request->input('period')) && in_array((int) $v, array_column($months, 'PeriodID'), true)
                ? tap((string) (int) $v, fn () => $query->where('PeriodID', (int) $v)) : null;

            $filters['group'] = ($v = $request->input('group')) && in_array($v, $mainGroups, true)
                ? tap($v, fn ($v) => $query->where('MainGroup', $v)) : null;

            // ── Stats (full filtered set, before pagination) ──────────────────
            // One monthly group-by (≤12 rows) powers both the grand total and the
            // highest-net-spend month; a second top-1 group-by gives the top
            // category. NetChange is netted of corrections, so "highest" is the
            // greatest *summed* net spend (a net-negative period ranks low).
            $byMonth = (clone $query)
                ->select('PeriodID', 'TRXPeriod')
                ->selectRaw('SUM(NetChange) AS total')
                ->groupBy('PeriodID', 'TRXPeriod')
                ->get();

            $highest = $byMonth->sortByDesc(fn ($m) => (float) $m->total)->first();

            $topCategoryRow = (clone $query)
                ->select('MainGroup')
                ->selectRaw('SUM(NetChange) AS total')
                ->groupBy('MainGroup')
                ->orderByDesc('total')
                ->first();

            $stats = [
                'totalExpenditure' => (float) $byMonth->sum(fn ($m) => (float) $m->total),
                'highestMonth' => [
                    'label' => $highest?->TRXPeriod,
                    'amount' => (float) ($highest?->total ?? 0),
                ],
                'topCategory' => [
                    'label' => $topCategoryRow?->MainGroup,
                    'amount' => (float) ($topCategoryRow?->total ?? 0),
                ],
            ];

            // ── Paginated results (raw line rows) ─────────────────────────────
            $rows = $query
                ->orderBy('PeriodID')
                ->orderBy('ClusterName')
                ->orderBy('InstitutionName')
                ->orderBy('Responsibility')
                ->orderBy('AccountNumber')
                ->orderBy('LineNumber')
                ->paginate(25)
                ->withQueryString();

        } catch (\Throwable $e) {
            session()->flash('warning', 'Could not connect to the financial data source. Please try again later.');

            $currentFiscalYear = $this->currentFiscalYear();
            $filters['fy'] = $filters['fy'] ?? $currentFiscalYear;

            return Inertia::render('Expenditure/Monthly Expenditure', [
                'rows' => new LengthAwarePaginator([], 0, 25, 1, [
                    'path' => $request->url(),
                    'query' => $request->query(),
                ]),
                'clusters' => [],
                'institutions' => [],
                'responsibilities' => [],
                'accounts' => [],
                'months' => [],
                'mainGroups' => [],
                'years' => [],
                'stats' => [
                    'totalExpenditure' => 0,
                    'highestMonth' => ['label' => null, 'amount' => 0],
                    'topCategory' => ['label' => null, 'amount' => 0],
                ],
                'filters' => $filters,
                'activeFiscalYear' => $filters['fy'],
                'currentFiscalYear' => $currentFiscalYear,
                'fyNav' => ['prev' => null, 'next' => null],
            ]);
        }

        return Inertia::render('Expenditure/Monthly Expenditure', [
            'rows' => $rows,
            'clusters' => $clusters,
            'institutions' => $institutions,
            'responsibilities' => $responsibilities,
            'accounts' => $accounts,
            'months' => $months,
            'mainGroups' => $mainGroups,
            'years' => $years,
            'stats' => $stats,
            'filters' => $filters,
            'activeFiscalYear' => $activeFiscalYear,
            'currentFiscalYear' => $currentFiscalYear,
            'fyNav' => $fyNav,
        ]);
    }
}
