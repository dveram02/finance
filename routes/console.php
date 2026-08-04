<?php

use Illuminate\Foundation\Inspiring;
use Illuminate\Support\Facades\Artisan;
use Illuminate\Support\Facades\Schedule;

Artisan::command('inspire', function () {
    $this->comment(Inspiring::quote());
})->purpose('Display an inspiring quote');

// =============================================================================
// Finance ledger snapshot
// =============================================================================
// Scheduled from Laravel rather than SQL Agent, because production's SQL Server
// edition is unconfirmed and Express has no Agent.
//
// CADENCE.
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
// withoutOverlapping() matters: a single year takes 74-175s on production, so a
// slow night must not stack runs.
//
// TODO: move the daily run to just after the GL load that populates
// 0098AFinGLMaster finishes — that window is still not confirmed.

Schedule::command('ledger:refresh')
    ->dailyAt('02:00')
    ->withoutOverlapping(config('ledger.refresh.timeout_seconds') / 60)
    ->onFailure(fn () => logger()->error('Scheduled finance ledger refresh failed.'));

Schedule::command('ledger:refresh --all')
    ->monthlyOn(1, '03:00')
    ->withoutOverlapping(config('ledger.refresh.timeout_seconds') / 60)
    ->onFailure(fn () => logger()->error('Scheduled full finance ledger rebuild failed.'));
