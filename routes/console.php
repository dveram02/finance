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
// Closed fiscal years never change, so the current and prior FY refresh nightly
// while the full 13-year loop runs weekly. withoutOverlapping() matters: a year
// takes 90-110 seconds to build, so a slow night must not stack runs.
//
// TODO: move the nightly run to just after the GL load that populates
// 0098AFinGLMaster finishes — that window is not yet confirmed.

Schedule::command('ledger:refresh')
    ->dailyAt('02:00')
    ->withoutOverlapping(config('ledger.refresh.timeout_seconds') / 60)
    ->onFailure(fn () => logger()->error('Scheduled finance ledger refresh failed.'));

Schedule::command('ledger:refresh --all')
    ->weeklyOn(0, '03:00')
    ->withoutOverlapping(config('ledger.refresh.timeout_seconds') / 60)
    ->onFailure(fn () => logger()->error('Scheduled full finance ledger rebuild failed.'));
