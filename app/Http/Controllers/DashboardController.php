<?php

namespace App\Http\Controllers;

use App\Concerns\ResolvesFiscalYear;
use App\Models\BudgetAllocation;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\Log;
use Inertia\Inertia;
use Inertia\Response;

class DashboardController extends Controller
{
    use ResolvesFiscalYear;

    public function index(Request $request): Response
    {
        $username = $request->user()->username;

        // The budget total drives the Total Budget KPI and the flat "Annual
        // Budget" reference line. It comes from vw_BudgetAllocation (the same
        // source as the Budget Allocations view) for the active fiscal year.
        ['fiscalYear' => $fiscalYear, 'totalBudget' => $totalBudget, 'available' => $budgetAvailable]
            = $this->budgetTotal($username);

        return Inertia::render('Dashboard', [
            'userName' => $request->user()->name,
            'fiscalYear' => $fiscalYear,
            'totalBudget' => $totalBudget,
            'budgetAvailable' => $budgetAvailable,
            'monthlyExpenditure' => $this->monthlyExpenditureData(),
            'budgetVsActual' => $this->budgetVsActualData($totalBudget),
            'expenditureByCategory' => $this->expenditureByCategoryData(),
        ]);
    }

    // =========================================================================
    // Live budget total — from vw_BudgetAllocation (current fiscal year)
    // =========================================================================

    /**
     * Resolve the active fiscal year and its total allocation for the user.
     * The source view joins remote GP linked servers, so both the year list
     * and the SUM are cached on the dedicated budget file store. A SQL Server
     * outage degrades to an unavailable state — never a fake zero budget.
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
    // Chart data helpers — actuals are placeholders until the chart SQL Server
    // is configured; only the budget reference line is live.
    // =========================================================================

    private function monthlyExpenditureData(): array
    {
        return [
            'labels' => ['November', 'December', 'January', 'February', 'March', 'April'],
            'datasets' => [
                [
                    'label' => 'Expenditure (TTD)',
                    'data' => [142500, 98300, 167200, 134800, 189600, 155400],
                ],
            ],
        ];
    }

    private function budgetVsActualData(float $totalBudget): array
    {
        $labels = ['November', 'December', 'January', 'February', 'March', 'April'];

        return [
            'labels' => $labels,
            'datasets' => [
                [
                    // Flat reference line at the full annual allocation.
                    'label' => 'Annual Budget',
                    'data' => array_fill(0, count($labels), $totalBudget),
                ],
                [
                    'label' => 'Actual',
                    'data' => [142500, 98300, 167200, 134800, 189600, 155400],
                ],
            ],
        ];
    }

    private function expenditureByCategoryData(): array
    {
        return [
            'labels' => ['Salaries', 'Medical Supplies', 'Utilities', 'Maintenance', 'Transport', 'Other'],
            'data' => [412000, 198500, 87300, 64200, 43100, 31900],
        ];
    }
}
