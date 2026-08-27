<?php

namespace App\Console\Commands;

use Illuminate\Console\Command;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;

/**
 * Rebuilds dbo.FinanceRequisitionSnapshot — the Phase 2 requisition-line detail.
 *
 * MANUAL RUNS ONLY, exactly like ledger:refresh. The scheduled refresh is step 2
 * of the SQL Server Agent job `SWRHA Finance - Ledger Refresh`
 * (sql/FinanceRequisitionAgentJobStep.sql). Do NOT add a Laravel
 * Schedule::command() entry: combined with the Agent job it double-schedules the
 * same proc, and neither proc takes an sp_getapplock, so nothing at the SQL layer
 * prevents two concurrent refreshes. Overlap is prevented solely by Agent
 * refusing to start a job that is already running.
 *
 * NO --year OPTION, AND THAT IS DELIBERATE. Unlike the ledger, this rebuilds
 * every fiscal year on every run: the whole history is ~106k rows and the
 * dominant cost — the shipment pre-aggregate — is paid once regardless of how
 * many years are built, so a per-year mode would be complexity bought with
 * nothing. The proc has no @Year parameter to pass.
 *
 * RUNNING THIS ALONE IS ALMOST NEVER RIGHT. The detail and the summary are the
 * same numbers at two grains, and the refresh proc's reconciliation gate refuses
 * to advance the detail past a summary it no longer ties to. If the data looks
 * stale, run the whole Agent job rather than this — see the warning printed on
 * the reconciliation-failure path below.
 */
class RefreshFinanceRequisition extends Command
{
    protected $signature = 'requisition:refresh
                            {--force : Bypass the movement sanity gates (never the zero-row or reconciliation gates)}';

    protected $description = 'Refresh the finance requisition detail snapshot on SQL Server';

    public function handle(): int
    {
        $force = $this->option('force') ? 1 : 0;

        $this->line('Rebuilding every fiscal year. The cost is dominated by the shipment');
        $this->line('pre-aggregate over dbo.0098FPOShipmentDetails — measure it on this run');
        $this->line('rather than trusting an estimate.');

        try {
            $result = DB::connection('FinanceAutomationSystem')
                ->select('EXEC dbo.usp_RefreshFinanceRequisition @Force = ?', [$force]);
        } catch (\Throwable $e) {
            // An aborted refresh leaves the previous snapshot in place — the app
            // keeps serving the last good data, so this is loud but not fatal.
            $this->error($e->getMessage());

            if (str_contains($e->getMessage(), 'RECONCILIATION FAILED')) {
                $this->newLine();
                $this->warn('The detail no longer ties to dbo.FinanceLedgerSnapshot.');
                $this->warn('This is the gate working, not a bug in it. Before forcing anything:');
                $this->warn('  1. run sql/Phase2ReconciliationTest.sql to see WHICH accounts drift;');
                $this->warn('  2. check whether the LEDGER is simply behind — a closed year that');
                $this->warn('     moved in the source will not reach the summary until the monthly');
                $this->warn('     full rebuild. Refreshing the ledger first usually resolves it.');
                $this->warn('--force does NOT bypass this gate, deliberately.');
            }

            Log::error('Finance requisition refresh failed.', ['exception' => $e->getMessage()]);

            return self::FAILURE;
        }

        $row = $result[0] ?? null;

        if ($row === null) {
            // The proc always returns a summary row on success, so no row means
            // something ran that was not this proc.
            $this->error('The refresh returned no result row. Confirm dbo.usp_RefreshFinanceRequisition is the version in sql/FinanceRequisition.sql.');

            return self::FAILURE;
        }

        $this->info(sprintf(
            '%s rows across %s fiscal years / %s accounts in %ss (Approved %s, Routing %s).',
            number_format((int) $row->RowsLoaded),
            $row->FiscalYearsLoaded,
            number_format((int) $row->AccountsLoaded),
            $row->DurationSeconds,
            $row->TotalApproved,
            $row->TotalRouting,
        ));

        $this->line(sprintf(
            'Reconciled %s account(s) against the ledger snapshot; %s mismatch(es).',
            number_format((int) $row->ReconAccountsCompared),
            $row->ReconMismatches,
        ));

        // Observations the proc records but does not abort on. Each has a reason
        // in sql/FinanceRequisition.sql; surfacing them here is the only place a
        // human routinely sees them.
        if ((int) $row->ReconStaleYearDrift > 0) {
            $this->warn(sprintf(
                '%s account(s) drift against fiscal years the LEDGER has not refreshed recently. '
                .'Expect the next full ledger rebuild to move them; investigate if it does not.',
                $row->ReconStaleYearDrift,
            ));
        }

        if ((int) $row->DuplicateGrainRows > 0) {
            $this->warn(sprintf(
                '%s row(s) share a (FinancialYear, RequisitionNumber, PONumber, LineNbr) key. '
                .'No money is duplicated — the totals reconcile — but Phase 3 needs a stable row key.',
                $row->DuplicateGrainRows,
            ));
        }

        if ((int) $row->UnparsedSegmentRows > 0) {
            $this->warn(sprintf(
                '%s row(s) have an account number the segment splitter could not parse. '
                .'They match no access grant and are invisible to every user — the same is true in the ledger.',
                $row->UnparsedSegmentRows,
            ));
        }

        return self::SUCCESS;
    }
}
