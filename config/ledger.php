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

    /*
    |--------------------------------------------------------------------------
    | Requisition Detail (Phase 2)
    |--------------------------------------------------------------------------
    |
    | dbo.FinanceRequisitionSnapshot is built by STEP 2 of the same SQL Server
    | Agent job that builds the ledger, immediately after step 1. The two are
    | deliberately in one job so both snapshots come from the same source state
    | — see financesqlupdatep2.md.
    |
    | max_run_drift_minutes is what turns that into something monitorable.
    | Agent steps cannot share a transaction, so step 1 can succeed while step 2
    | fails: the summary advances, the detail does not, and BOTH tables still
    | look individually fresh. The only symptom is that their RefreshedAt values
    | stop coming from the same run, which is what `php artisan ledger:status`
    | asserts.
    |
    | The default must exceed the LEDGER STEP'S OWN DURATION, because step 2
    | cannot start until step 1 finishes. Measured on production 2026-08-05, a
    | full 13-year ledger rebuild took ~43 minutes; the nightly current+prior-FY
    | run takes ~8. 180 minutes leaves headroom above the monthly worst case
    | without being so loose that a missed nightly step 2 hides inside it.
    |
    | RE-MEASURE after the 2026-08-25 change — the ledger function no longer
    | touches the linked server and builds one FY in ~22s on dev, so the real
    | figure is very likely far smaller and this can be tightened.
    |
    | PHASE 3 adds the two cache settings below. They exist SEPARATELY from
    | ledger.cache on purpose: the requisition pages version their filter lists
    | against dbo.FinanceRequisitionRefresh (see
    | App\Concerns\VersionsRequisitionCache), because the two snapshots are
    | built by two STEPS of one Agent job and can legitimately diverge. Sharing
    | the ledger's knobs would work today and would quietly become wrong the
    | first time someone tuned one of them.
    |
    | cache_minutes is only a backstop — the version stamp is the primary
    | invalidation, exactly as for the ledger.
    |
    */

    'requisition' => [
        'max_run_drift_minutes' => (int) env('FINANCE_REQUISITION_MAX_DRIFT_MINUTES', 180),
        'cache_minutes' => (int) env('FINANCE_REQUISITION_CACHE_MINUTES', 10),

        // How long the RefreshedAt probe is cached. It gates every requisition
        // cache key AND is rendered on the page as "last refreshed", so it must
        // stay short: a user must never be told the data is fresher than the
        // cache they are being served from.
        'version_seconds' => (int) env('FINANCE_REQUISITION_VERSION_SECONDS', 60),
    ],

];
