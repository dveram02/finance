<?php

return [

    /*
    |--------------------------------------------------------------------------
    | Budget Allocation Filter Cache
    |--------------------------------------------------------------------------
    |
    | The budget-allocations page caches its filter dropdown lists (they depend
    | only on user + fiscal year). These settings control where and for how long
    | those lists are cached. A dedicated store keeps this off the default app
    | cache; expiry is time based since the source data is read-only SQL Server.
    |
    */

    'cache' => [
        'store' => 'file',
        'minutes' => (int) env('BUDGET_ALLOCATION_CACHE_MINUTES', 10),
    ],

];
