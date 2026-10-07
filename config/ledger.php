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

        /*
        | ── Snapshot staleness, ONE definition ─────────────────────────────
        |
        | The age at which the snapshot is called stale, in hours. Read by BOTH
        | `ledger:status` (as its --max-age-hours default) and the two detail
        | pages, which surface staleness in their context strip. That sharing is
        | the point: two definitions of "stale" would drift, and the page would
        | reassure a user the health check was already alerting on.
        |
        | 36h, because the Agent job runs daily at 21:30 — so anything past 36h
        | means at least one nightly run was missed. Note a FAILED run is a
        | separate signal, not an age: the refresh log is run-keyed and an
        | aborted run appends an ABORTED row while the previous snapshot stands,
        | so the newest row's Outcome is what reveals it. Freshness is measured
        | against the last OK row; the alert is the newest row.
        */
        'max_age_hours' => (int) env('FINANCE_REQUISITION_MAX_AGE_HOURS', 36),

        /*
        | ── Grace period for a BRAND-NEW fiscal year (added 2026-10-07) ─────
        |
        | `ledger:status` asserts that the CURRENT fiscal year has been built,
        | and the current year comes from the clock: FY2027 begins on
        | 1 Oct 2026. But the refresh enumerates fiscal years FROM THE SOURCE
        | (0098AFinGLMaster UNION 0040CBudgetsAllocation) rather than from a
        | calendar range, so a year with no source rows is never attempted and
        | never logged.
        |
        | MEASURED 2026-10-07, one day after go-live: FY2027 had 0 rows in both
        | source tables, the latest GL posting of ANY year was 2026-08-31, and
        | `ledger:status` reported "CRITICAL: fiscal year 2027 has never been
        | built" while the nightly job had in fact run correctly and succeeded.
        |
        | 🔴 THAT IS THE FAILURE MODE THAT KILLS MONITORING. Left alone the
        | check would alert every day from 1 October until FY2027 data appears -
        | possibly weeks - and an alarm that cries wolf for weeks gets muted,
        | after which the real stoppage is silent too. Worse than no check.
        |
        | So a missing current year is treated as EXPECTED while BOTH hold:
        | the source has no rows for it, AND the fiscal year is less than this
        | many days old. Freshness is then asserted against the newest year that
        | WAS built, so a genuinely stopped scheduler still alarms.
        |
        | Past the grace period a dataless current year becomes CRITICAL again,
        | because by then it means nobody ever loaded the allocations - which is
        | a real problem that would otherwise stay quiet forever. 90 days runs
        | to the end of December.
        |
        | Set to 0 to restore the old unconditional CRITICAL.
        */
        'current_year_grace_days' => (int) env('FINANCE_CURRENT_YEAR_GRACE_DAYS', 90),

        /*
        | ── Bounded-fetch guard (routingupdate.md §6) ──────────────────────
        |
        | Since 2026-10-01 the fiscal year is an OPTIONAL filter on the two
        | detail pages, so the default scope is every eligible year rather than
        | one. detailRows() therefore fetches with LIMIT row_ceiling + 1 and
        | getting ceiling + 1 rows back IS the too-large signal — one statement,
        | no COUNT(*) pre-flight to race or bypass.
        |
        | INVARIANTS, enforced by App\Support\RequisitionScopeThresholds:
        | row_ceiling >= 0; 0 DISABLES THE GUARD ENTIRELY (both refusal and
        | warnings) and is not for production; row_warn is clamped below
        | row_ceiling, and 0 disables warnings alone. Anything unparseable
        | falls back to the DEFAULT, never to "no limit".
        |
        | Measured 2026-10-01 (CLI, full pipeline, peak process memory):
        | 416 rows for the only mapped user; 93,336 rows / 558 MB unbounded if
        | a user were mapped to everything; 25,001 rows / 172 MB bounded;
        | largest SINGLE year 18,945. Production memory_limit is 4096M on a
        | shared php.ini, so 25,000 is a USABILITY limit, not a memory one —
        | 93,336 rows is a ~5.1 s response and 3,734 pages of 25.
        |
        | NOT (int) env(...) on purpose. `(int) 'abc'` is 0, and 0 is the
        | explicit opt-out, so a typo in .env would SILENTLY DISABLE the guard.
        | The raw value is passed through and validated in one place.
        */

        'row_ceiling' => env('FINANCE_REQUISITION_ROW_CEILING', 25000),

        // A "watch this" line, not an error. 10,000 would fire on FOUR normal
        // single-year AP/PO views for a broadly-mapped user (18,945 / 16,045 /
        // 14,025 / 13,657), so it is set above the largest ordinary single
        // year — re-set it once that is measured on production, or the signal
        // is noise. Raw, as above.
        'row_warn' => env('FINANCE_REQUISITION_ROW_WARN', 20000),
    ],

];
