<?php

namespace App\Console\Commands;

use Illuminate\Console\Command;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\DB;

/**
 * Reports the freshness of the finance ledger snapshot.
 *
 * This is the health check for the one failure this application cannot detect
 * on its own: the scheduler stopping. If the refresh never runs, nothing errors
 * — pages keep loading fast and the figures simply stop moving — so staleness
 * has to be asserted against the clock rather than waiting for a failure.
 *
 * Returns a NON-ZERO exit code when the current fiscal year's snapshot is older
 * than --max-age-hours, so Task Scheduler and scripts/check-ledger-health.ps1
 * can alert on it.
 */
class LedgerStatus extends Command
{
    protected $signature = 'ledger:status
                            {--max-age-hours=36 : Age at which the current FY snapshot is considered stale}
                            {--json : Output raw JSON instead of a table}';

    protected $description = 'Report finance ledger snapshot freshness; exit non-zero if stale';

    public function handle(): int
    {
        $maxAge = (int) $this->option('max-age-hours');

        try {
            $rows = DB::connection('FinanceAutomationSystem')
                ->table('FinanceLedgerRefresh')
                ->orderBy('FinancialYear')
                ->get();
        } catch (\Throwable $e) {
            $this->error('Could not read dbo.FinanceLedgerRefresh: '.$e->getMessage());

            return self::FAILURE;
        }

        if ($rows->isEmpty()) {
            $this->error('The ledger snapshot has never been built. Run: php artisan ledger:refresh --all');

            return self::FAILURE;
        }

        $currentFy = (string) (now()->month >= 10 ? now()->year + 1 : now()->year);
        $current = $rows->firstWhere('FinancialYear', $currentFy);
        $aborted = $rows->where('Outcome', '!=', 'OK');

        // Operand order matters: Carbon 3's diffInHours is SIGNED and returns
        // ($other - $this). It must read refreshedAt->diffInHours(now()) so a
        // past refresh yields a POSITIVE age. Reversed, every age comes back
        // negative, the `> $maxAge` test can never be true, and this command
        // reports OK forever — silently disabling the one check that catches a
        // stopped scheduler.
        $ageHours = $current
            ? round(Carbon::parse($current->RefreshedAt)->diffInHours(now()), 1)
            : null;

        if ($this->option('json')) {
            $this->line(json_encode([
                'currentFiscalYear' => $currentFy,
                'refreshedAt' => $current->RefreshedAt ?? null,
                'ageHours' => $ageHours,
                'maxAgeHours' => $maxAge,
                'rowsLoaded' => $current->RowsLoaded ?? null,
                'abortedYears' => $aborted->pluck('FinancialYear')->all(),
                'stale' => $current === null || $ageHours > $maxAge,
            ], JSON_PRETTY_PRINT));
        } else {
            $this->table(
                ['FY', 'Refreshed At', 'Rows', 'Secs', 'Outcome', 'Message'],
                $rows->map(fn ($r) => [
                    $r->FinancialYear, $r->RefreshedAt, $r->RowsLoaded,
                    $r->DurationSeconds, $r->Outcome, $r->Message,
                ])->all()
            );
        }

        // ── Verdicts, most severe first ──────────────────────────────────────
        if ($current === null) {
            $this->error("CRITICAL: fiscal year {$currentFy} has never been built.");

            return self::FAILURE;
        }

        if ($ageHours > $maxAge) {
            $this->error("CRITICAL: FY{$currentFy} snapshot is {$ageHours}h old (limit {$maxAge}h). The scheduler is probably not running.");

            return self::FAILURE;
        }

        if ($aborted->isNotEmpty()) {
            // Aborted years are serving their previous good snapshot, so this is
            // a warning rather than a failure — but it will not self-resolve.
            $this->warn('WARNING: aborted refresh for FY '.$aborted->pluck('FinancialYear')->implode(', ').'. Previous snapshot retained.');

            return self::FAILURE;
        }

        $this->info("OK: FY{$currentFy} snapshot is {$ageHours}h old ({$current->RowsLoaded} rows).");

        return self::SUCCESS;
    }
}
