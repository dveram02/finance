<?php

use Illuminate\Foundation\Inspiring;
use Illuminate\Support\Facades\Artisan;

Artisan::command('inspire', function () {
    $this->comment(Inspiring::quote());
})->purpose('Display an inspiring quote');

// =============================================================================
// Finance ledger snapshot — SCHEDULED IN SQL SERVER AGENT, NOT HERE
// =============================================================================
// An earlier revision registered the refresh here, justified by "production's
// SQL Server edition is unconfirmed and Express has no Agent". That was wrong:
// the instance is NAMED sqlapp\SQLEXPRESS but its edition is Standard (2022,
// EngineEdition 2), Agent is running and Agent XPs is enabled.
//
// The refresh is nothing but an EXEC of a stored procedure, so it now lives in
// the Agent job `SWRHA Finance - Ledger Refresh` — see sql/FinanceLedgerAgentJob.sql
// and instructionsforschedule.md. That removed 1,440 php.exe bootstraps a day,
// and removed a MySQL dependency from a SQL Server refresh (withoutOverlapping()
// keeps its lock in the default cache store, so MySQL being down blocked a job
// that never touches MySQL). Agent refuses to start a job that is already
// running, which is a direct replacement for that lock.
//
// DO NOT re-register the schedule here. `ledger:refresh` still exists for manual
// runs, but a Laravel entry plus the Agent job would double-schedule the same
// proc, and nothing at the SQL layer prevents two concurrent refreshes — see the
// sp_getapplock note in sql/FinanceLedgerAgentJob.sql, Appendix A.
//
// CADENCE (implemented in the Agent job step, documented here because this is
// where anyone looks first).
//
// A fiscal period closes mid-to-late within its OWN month - July closes in
// July - so by the 1st of the following month the previous month is complete.
// Executives read the previous month and back, so a monthly refresh on the 1st
// would satisfy the reporting requirement on its own.
//
// So why keep a DAILY run at all? Not for freshness - for RESILIENCE.
//
// With a monthly-only schedule, one failed run leaves the figures stale for up
// to 31 days. The sanity gates in usp_RefreshFinanceLedgerSnapshot deliberately
// keep the PREVIOUS snapshot when a build looks wrong, so a linked-server blip
// on the 1st means executives read last month's numbers for a month, and only
// the health check would notice. Daily turns that single point of failure into
// ~30 chances, and costs ~2-6 minutes a night because it rebuilds only the
// current and prior fiscal year.
//
// The 16-38 minute figure is the full 13-year loop, which runs monthly because
// closed fiscal years genuinely never change.
//
// NOTE: encumbrances are SNAPSHOTTED, not live (see dbo.vw_FinanceLedger).
// An earlier revision read them live so allocation balances were accurate
// intraday; that was reverted once it was established nobody uses the balance
// as a current-state figure. If that ever changes, fix it by changing THIS
// CADENCE, not by making one column live - live encumbrance against a
// snapshotted GL makes balances read high, which is the wrong direction.
//
// The Agent job runs at 21:30 — after the business day, and clear of the 01:15
// backup, syspolicy_purge_history at 02:00, and Nexus at 00:00/01:00/02:00.
//
// It assumes the external process that loads 0098AFinGLMaster runs during the
// DAY. That process is not an Agent job on this instance (a search of
// sysjobsteps for 0098A / GPSWRHA / GL found nothing) and the table is local to
// FinanceAutomationSystem, so something outside writes it and its window is
// unconfirmed. If it turns out to run overnight, 21:30 reads before the load
// lands and the snapshot sits a day behind — sql/FinanceLedgerAgentJob.sql
// section 5 has the queries that settle it.
