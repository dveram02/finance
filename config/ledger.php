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
    | Measured build cost for ONE fiscal year, from dbo.FinanceLedgerRefresh on
    | PRODUCTION (2026-08-05): 102-256s, ~230s for a recent year. The whole
    | 13-year loop logged 2,595s — roughly 43 minutes, not the 16-38 estimated
    | from the replica. The nightly current+prior-FY run costs ~8 minutes.
    |
    | recent_years drives `php artisan ledger:refresh` when no --year is given.
    | It is a MANUAL-RUN setting now: the scheduled refresh moved to the SQL
    | Server Agent job `SWRHA Finance - Ledger Refresh`, which computes the same
    | window in T-SQL (@FromYear = current FY - 1). If you change this value,
    | change the arithmetic in sql/FinanceLedgerAgentJob.sql to match.
    |
    | timeout_seconds is RETAINED BUT UNUSED. It was the expiry on the
    | withoutOverlapping() lock in routes/console.php; that schedule is gone, and
    | overlap is now prevented by Agent refusing to start a job that is already
    | running. Kept so an existing FINANCE_LEDGER_REFRESH_TIMEOUT in a
    | production .env does not read as a setting that stopped working silently.
    | Safe to delete once the .env files are cleaned up.
    |
    */

    'refresh' => [
        'recent_years' => (int) env('FINANCE_LEDGER_REFRESH_RECENT_YEARS', 2),
        'timeout_seconds' => (int) env('FINANCE_LEDGER_REFRESH_TIMEOUT', 7200),
    ],

];
