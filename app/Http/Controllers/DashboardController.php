<?php

namespace App\Http\Controllers;

use App\Concerns\DashboardDataTransforms;
use App\Concerns\ResolvesFiscalYear;
use App\Models\BudgetAllocation;
use App\Models\MonthlyExpenditure;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Log;
use Inertia\Inertia;
use Inertia\Response;

class DashboardController extends Controller
{
    use DashboardDataTransforms;
    use ResolvesFiscalYear;

    public function index(Request $request): Response
    {
        $username = $request->user()->username;

        // The budget total drives the Total Budget KPI and the flat "Annual
        // Budget" reference line. It comes from vw_BudgetAllocation (the same
        // source as the Budget Allocations view) for the active fiscal year.
        ['fiscalYear' => $fiscalYear, 'totalBudget' => $totalBudget, 'available' => $budgetAvailable]
            = $this->budgetTotal($username);

        // The expenditure window is "up to the current fiscal month" for the
        // active FY (whole year for a past FY, nothing for a future FY).
        $cutoff = $this->resolveCutoff($fiscalYear);

        $expenditure = $this->expenditureData($username, $fiscalYear, $cutoff);

        return Inertia::render('Dashboard', [
            'userName' => $request->user()->name,
            'fiscalYear' => $fiscalYear,
            'totalBudget' => $totalBudget,
            'budgetAvailable' => $budgetAvailable,
            'expenditureAvailable' => $expenditure['available'],
            'expenditureWindowStarted' => $cutoff > 0,
            'ytdExpenditure' => $expenditure['ytd'],
            'latestPeriodLabel' => $expenditure['latestPeriodLabel'],
            'monthlyExpenditure' => $this->monthlyBarData($fiscalYear, $cutoff, $expenditure['periodTotals']),
            'budgetVsActual' => $this->budgetVsActualData(
                $totalBudget,
                $budgetAvailable,
                $expenditure['available'],
                $fiscalYear,
                $cutoff,
                $expenditure['periodTotals']
            ),
            'expenditureByCategory' => $expenditure['byCategory'],
        ]);
    }

    // =========================================================================
    // Live budget total — from vw_BudgetAllocation (current fiscal year)
    // =========================================================================

    /**
     * Resolve the active fiscal year and its total allocation for the user.
     * The source view joins remote GP linked servers, so both the year list
     * and the SUM are cached on the dedicated budget file store. A SQL Server
     * outage degrades to an unavailable state — never a fake zero budget. A
     * successful query that returns no years for the user is also treated as
     * unavailable (no budget configured ≠ a real zero allocation).
     *
     * @return array{fiscalYear:int, totalBudget:float, available:bool}
     */
    private function budgetTotal(string $username): array
    {
        $cache = Cache::store(config('budget.cache.store'));
        $ttl = config('budget.cache.minutes') * 60;
        $currentFiscalYear = $this->currentFiscalYear();

        try {
            // Reuse the exact cache key the Budget Allocations view populates.
            $years = collect($cache->remember(
                "budget-allocations:years:{$username}",
                $ttl,
                fn () => BudgetAllocation::forUser($username)
                    ->select('FinancialYear')
                    ->distinct()
                    ->orderBy('FinancialYear')
                    ->pluck('FinancialYear')
                    ->filter()
                    ->values()
                    ->all()
            ));

            if ($years->isEmpty()) {
                // Query succeeded but this user has no budget data — not a real zero.
                return [
                    'fiscalYear' => $currentFiscalYear,
                    'totalBudget' => 0.0,
                    'available' => false,
                ];
            }

            $activeFiscalYear = $this->resolveFiscalYear(null, $years, $currentFiscalYear);

            $totalBudget = (float) $cache->remember(
                "dashboard:budget-total:{$username}:{$activeFiscalYear}",
                $ttl,
                fn () => BudgetAllocation::forUser($username)
                    ->forYear((string) $activeFiscalYear)
                    ->sum('TotalAllocation')
            );

            return [
                'fiscalYear' => $activeFiscalYear,
                'totalBudget' => $totalBudget,
                'available' => true,
            ];
        } catch (\Throwable $e) {
            Log::error('Dashboard budget total query failed.', [
                'username' => $username,
                'fy' => $currentFiscalYear,
                'exception' => $e->getMessage(),
            ]);

            return [
                'fiscalYear' => $currentFiscalYear,
                'totalBudget' => 0.0,
                'available' => false,
            ];
        }
    }

    // =========================================================================
    // Live expenditure — from dbo.MonthlyExpenditure (active FY, up to cutoff)
    // =========================================================================

    /**
     * Per-month net expenditure for the active FY up to $cutoff, plus the YTD
     * total and a net-by-category breakdown. Read-only SQL Server source, so it
     * is wrapped in try/catch and degrades to an unavailable state. Cached on the
     * dedicated expenditure file store — the dashboard takes no per-request
     * filters, so the only cache dimensions are (user, FY, cutoff).
     *
     * @return array{available:bool, ytd:float, latestPeriodLabel:?string,
     *               periodTotals:array<int,array{PeriodID:int,TRXPeriod:string,total:float}>,
     *               byCategory:array{labels:array<int,string>, data:array<int,float>}}
     */
    private function expenditureData(string $username, int $fiscalYear, int $cutoff): array
    {
        $cache = Cache::store(config('expenditure.cache.store'));
        $ttl = config('expenditure.cache.minutes') * 60;

        try {
            // $cutoff is in the key so the cache rolls forward when the fiscal
            // month advances; stale keys expire on their own TTL.
            return $cache->remember(
                "dashboard:expenditure:{$username}:{$fiscalYear}:{$cutoff}",
                $ttl,
                function () use ($username, $fiscalYear, $cutoff) {
                    $base = fn () => MonthlyExpenditure::forUser($username)
                        ->forYear((string) $fiscalYear)
                        ->where('PeriodID', '<=', $cutoff);

                    // Per-month net (≤ cutoff rows): powers YTD, the bar chart,
                    // and the cumulative Actual line.
                    $byMonth = $base()
                        ->select('PeriodID', 'TRXPeriod')
                        ->selectRaw('SUM(NetChange) AS total')
                        ->groupBy('PeriodID', 'TRXPeriod')
                        ->orderBy('PeriodID')
                        ->get();

                    // Net by category (MainGroup); negatives allowed (bar chart).
                    $byCat = $base()
                        ->select('MainGroup')
                        ->selectRaw('SUM(NetChange) AS total')
                        ->groupBy('MainGroup')
                        ->orderByDesc('total')
                        ->get();

                    // SUM(NetChange) is uncast → comes back a string; cast to float.
                    $periodTotals = $byMonth->map(fn ($m) => [
                        'PeriodID' => (int) $m->PeriodID,
                        'TRXPeriod' => $m->TRXPeriod,
                        'total' => (float) $m->total,
                    ])->all();

                    return [
                        'available' => true,
                        'ytd' => (float) array_sum(array_column($periodTotals, 'total')),
                        // The CURRENT fiscal month (not the last row) — so "through
                        // JUN, 26" is correct even before the current month posts.
                        'latestPeriodLabel' => $this->fiscalMonthLabels($fiscalYear)[$cutoff] ?? null,
                        'periodTotals' => $periodTotals,
                        'byCategory' => $this->topCategories($byCat, 8),
                    ];
                }
            );
        } catch (\Throwable $e) {
            Log::error('Dashboard expenditure query failed.', [
                'username' => $username,
                'fy' => $fiscalYear,
                'exception' => $e->getMessage(),
            ]);

            return [
                'available' => false,
                'ytd' => 0.0,
                'latestPeriodLabel' => null,
                'periodTotals' => [],
                'byCategory' => ['labels' => [], 'data' => []],
            ];
        }
    }

    // =========================================================================
    // Chart shaping — budget burn-up (flat annual budget + cumulative actual)
    // =========================================================================

    private function budgetVsActualData(
        float $totalBudget,
        bool $budgetAvailable,
        bool $expenditureAvailable,
        int $fiscalYear,
        int $cutoff,
        array $periodTotals
    ): array {
        $labels = array_values($this->fiscalMonthLabels($fiscalYear));   // 12 labels, period order

        // Blank the actual line entirely when the source is down (all null) so it
        // is never mistaken for genuine zero spend. A real new FY with no rows yet
        // still shows a legitimate cumulative 0 because $expenditureAvailable is true.
        $actual = $expenditureAvailable
            ? $this->cumulativeSeries($cutoff, $periodTotals)
            : array_fill(0, 12, null);

        $datasets = [];
        // No fake budget line when the budget source is unavailable — omit it.
        if ($budgetAvailable) {
            $datasets[] = ['label' => 'Annual Budget', 'data' => array_fill(0, 12, $totalBudget)];
        }
        $datasets[] = ['label' => 'Actual (cumulative)', 'data' => $actual];

        return ['labels' => $labels, 'datasets' => $datasets];
    }
}
