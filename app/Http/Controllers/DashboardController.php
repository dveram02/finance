<?php

namespace App\Http\Controllers;

use Illuminate\Http\Request;
use Inertia\Inertia;
use Inertia\Response;

class DashboardController extends Controller
{
    public function index(Request $request): Response
    {
        return Inertia::render('Dashboard', [
            'userName'              => $request->user()->name,
            'monthlyExpenditure'    => $this->monthlyExpenditureData(),
            'budgetVsActual'        => $this->budgetVsActualData(),
            'expenditureByCategory' => $this->expenditureByCategoryData(),
        ]);
    }

    // =========================================================================
    // Chart data helpers — replace with live SQL Server queries later
    // =========================================================================

    private function monthlyExpenditureData(): array
    {
        return [
            'labels' => ['November', 'December', 'January', 'February', 'March', 'April'],
            'datasets' => [
                [
                    'label' => 'Expenditure (TTD)',
                    'data'  => [142500, 98300, 167200, 134800, 189600, 155400],
                ],
            ],
        ];
    }

    private function budgetVsActualData(): array
    {
        return [
            'labels' => ['November', 'December', 'January', 'February', 'March', 'April'],
            'datasets' => [
                [
                    'label' => 'Budget',
                    'data'  => [160000, 160000, 175000, 175000, 175000, 175000],
                ],
                [
                    'label' => 'Actual',
                    'data'  => [142500, 98300, 167200, 134800, 189600, 155400],
                ],
            ],
        ];
    }

    private function expenditureByCategoryData(): array
    {
        return [
            'labels' => ['Salaries', 'Medical Supplies', 'Utilities', 'Maintenance', 'Transport', 'Other'],
            'data'   => [412000, 198500, 87300, 64200, 43100, 31900],
        ];
    }
}
