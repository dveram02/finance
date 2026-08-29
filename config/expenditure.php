<?php

return [

    /*
    |--------------------------------------------------------------------------
    | Dashboard Expenditure Cache
    |--------------------------------------------------------------------------
    |
    | This once configured the filter dropdown lists of the per-period Monthly
    | Expenditure page, which read dbo.MonthlyExpenditure. THAT PAGE IS GONE —
    | the name and the /monthly-expenditure URL now belong to the ledger-backed
    | account x month grid, which caches against config/ledger.php.
    |
    | The remaining reader is DashboardController::expenditureData(), whose
    | `dashboard:expenditure:{user}:{fy}:{cutoff}` entries hold the monthly bar
    | chart, the YTD figure and the category breakdown. That path still queries
    | dbo.MonthlyExpenditure, which is why both the model and the SQL view stay.
    |
    | The env var keeps its MONTHLY_EXPENDITURE_ name so an existing production
    | .env does not silently stop being read. Same `file` store as the budget and
    | ledger caches, so `php artisan cache:clear file` clears all three.
    |
    */

    'cache' => [
        'store' => 'file',
        'minutes' => (int) env('MONTHLY_EXPENDITURE_CACHE_MINUTES', 10),
    ],

];
