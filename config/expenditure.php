<?php

return [

    /*
    |--------------------------------------------------------------------------
    | Monthly Expenditure Filter Cache
    |--------------------------------------------------------------------------
    |
    | The monthly-expenditure page caches its filter dropdown lists (they depend
    | only on user + fiscal year). These settings control where and for how long
    | those lists are cached. Kept separate from config/budget.php so the two
    | pages — which have different query cost and option lists — can be tuned
    | independently. Both use the `file` store, so `php artisan cache:clear file`
    | clears both.
    |
    */

    'cache' => [
        'store' => 'file',
        'minutes' => (int) env('MONTHLY_EXPENDITURE_CACHE_MINUTES', 10),
    ],

];
