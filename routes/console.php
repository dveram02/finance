<?php

use Illuminate\Foundation\Inspiring;
use Illuminate\Support\Facades\Artisan;
use Illuminate\Support\Facades\Schedule;

Artisan::command('inspire', function () {
    $this->comment(Inspiring::quote());
})->purpose('Display an inspiring quote');

// Generate draft requisitions 7 days before each scheduled delivery date
Schedule::command('requisitions:generate-scheduled-drafts')
    ->dailyAt('00:00')  // 00:00 for 12am
    ->withoutOverlapping()
    ->runInBackground();

// Notify HOD and clerks when a scheduled draft hasn't been submitted 3 days before delivery
Schedule::command('requisitions:notify-overdue-scheduled')
    ->dailyAt('01:00')
    ->withoutOverlapping()
    ->runInBackground();

// Sync reason_code + reason_description from GP vw_ReasonCodeInventoryAccounts
Schedule::command('gp:sync-reason-codes')
    ->dailyAt('02:00')
    ->withoutOverlapping()
    ->runInBackground();

// Prune stale audit log entries (retention policy defined on AuditEntry + ActivityEntry models)
Schedule::command('model:prune', [
    '--model' => [
        \App\Models\Audit\AuditEntry::class,
        \App\Models\Audit\ActivityEntry::class,
    ],
])->weekly()->sundays()->at('03:00');
