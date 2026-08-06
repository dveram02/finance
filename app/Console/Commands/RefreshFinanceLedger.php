<?php

namespace App\Console\Commands;

use Illuminate\Console\Command;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;

/**
 * Rebuilds dbo.FinanceLedgerSnapshot.
 *
 * MANUAL RUNS ONLY. The scheduled refresh is the SQL Server Agent job
 * `SWRHA Finance - Ledger Refresh` (sql/FinanceLedgerAgentJob.sql). An earlier
 * revision scheduled this command from routes/console.php on the grounds that
 * production's edition was unconfirmed and Express has no Agent — the instance
 * is merely NAMED sqlapp\SQLEXPRESS; its edition is Standard 2022 and Agent is
 * running. Do not re-add a Schedule entry: it would double-schedule the proc.
 *
 * The refresh is year-at-a-time by design: every call pushes a sargable
 * FinancialYear into the source function's CTEs, and closed fiscal years never
 * change — so the recent years can refresh often and the full loop rarely.
 */
class RefreshFinanceLedger extends Command
{
    protected $signature = 'ledger:refresh
                            {--year=* : Specific fiscal year(s) to refresh, e.g. --year=2026}
                            {--all : Refresh every fiscal year present in the source}
                            {--force : Bypass the movement sanity gates (never the zero-row gate)}';

    protected $description = 'Refresh the finance ledger snapshot on SQL Server';

    public function handle(): int
    {
        $force = $this->option('force') ? 1 : 0;

        try {
            if ($this->option('all')) {
                return $this->refreshAll($force);
            }

            $years = $this->option('year') ?: $this->recentYears();

            return $this->refreshYears($years, $force);
        } catch (\Throwable $e) {
            // A refresh failure leaves the previous snapshot in place — the app
            // keeps serving the last good data, so this is loud but not fatal.
            $this->error($e->getMessage());
            Log::error('Finance ledger refresh failed.', ['exception' => $e->getMessage()]);

            return self::FAILURE;
        }
    }

    // =========================================================================
    // Refresh modes
    // =========================================================================

    /**
     * @param  array<int,string>  $years
     */
    private function refreshYears(array $years, int $force): int
    {
        $failed = 0;

        foreach ($years as $year) {
            $this->line("Refreshing FY{$year}...");

            try {
                $result = DB::connection('FinanceAutomationSystem')
                    ->select('EXEC dbo.usp_RefreshFinanceLedgerSnapshot @FinancialYear = ?, @Force = ?', [(string) $year, $force]);

                $row = $result[0] ?? null;

                $this->info(sprintf(
                    'FY%s: %s rows in %ss (allocation %s, YTD %s)',
                    $year,
                    $row->RowsLoaded ?? '?',
                    $row->DurationSeconds ?? '?',
                    $row->TotalAllocation ?? '?',
                    $row->TotalYTD ?? '?',
                ));
            } catch (\Throwable $e) {
                // Keep going: one bad year must not block the rest, and the
                // proc has already rolled that year back to its last good load.
                $failed++;
                $this->error("FY{$year}: ".$e->getMessage());
                Log::error('Finance ledger refresh failed for a fiscal year.', [
                    'fiscalYear' => $year,
                    'exception' => $e->getMessage(),
                ]);
            }
        }

        return $failed === 0 ? self::SUCCESS : self::FAILURE;
    }

    private function refreshAll(int $force): int
    {
        $this->line('Refreshing every fiscal year — this takes roughly 90-110 seconds per year.');

        DB::connection('FinanceAutomationSystem')
            ->statement('EXEC dbo.usp_RefreshFinanceLedgerSnapshotAll @Force = ?', [$force]);

        $this->info('All fiscal years refreshed.');

        return self::SUCCESS;
    }

    /**
     * The current fiscal year and the configured number of years before it.
     *
     * A fiscal year runs Oct 1 → Sep 30 and is named for the year it ends in,
     * so October rolls the window forward. Mirrors
     * App\Concerns\ResolvesFiscalYear::currentFiscalYear(); not reused from the
     * trait because that is a controller concern and this is a console one.
     *
     * @return array<int,string>
     */
    private function recentYears(): array
    {
        $now = now();
        $current = $now->month >= 10 ? $now->year + 1 : $now->year;
        $count = max(1, (int) config('ledger.refresh.recent_years'));

        return collect(range(0, $count - 1))
            ->map(fn (int $offset) => (string) ($current - $offset))
            ->all();
    }
}
