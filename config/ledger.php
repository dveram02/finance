<?php

return [

    /*
    |--------------------------------------------------------------------------
    | Finance Ledger Cache
    |--------------------------------------------------------------------------
    |
    | The ledger pages cache their filter dropdown lists (they depend only on
    | user + fiscal year). Mirrors config/budget.php: a dedicated store keeps
    | this off the default MySQL app cache.
    |
    | Unlike the budget and expenditure caches, these keys are also VERSIONED
    | by the snapshot's RefreshedAt (see App\Concerns\VersionsLedgerCache), so
    | a refresh invalidates them immediately rather than after the TTL. The TTL
    | is therefore a backstop, not the primary invalidation.
    |
    */

    'cache' => [
        'store' => 'file',
        'minutes' => (int) env('FINANCE_LEDGER_CACHE_MINUTES', 10),

        // How long the RefreshedAt probe itself is cached. Short, because it
        // gates every other key; a request may serve data up to this many
        // seconds stale after a refresh.
        'version_seconds' => (int) env('FINANCE_LEDGER_VERSION_SECONDS', 60),
    ],

    /*
    |--------------------------------------------------------------------------
    | Snapshot Refresh
    |--------------------------------------------------------------------------
    |
    | The scheduled refresh (App\Console\Commands\RefreshFinanceLedger) rebuilds
    | the current and prior fiscal years often, since closed years never change.
    | The full loop is a separate, rarer schedule.
    |
    | Each fiscal year takes roughly 90-110 seconds to build on the replica, so
    | the command runs without overlapping and with a generous timeout.
    |
    */

    'refresh' => [
        'recent_years' => (int) env('FINANCE_LEDGER_REFRESH_RECENT_YEARS', 2),
        'timeout_seconds' => (int) env('FINANCE_LEDGER_REFRESH_TIMEOUT', 1800),
    ],

];
