<?php

namespace App\Console\Commands;

use Illuminate\Console\Command;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\DB;

/**
 * Reports the freshness of the finance snapshots — BOTH of them.
 *
 * This is the health check for the one failure this application cannot detect
 * on its own: the scheduler stopping. If the refresh never runs, nothing errors
 * — pages keep loading fast and the figures simply stop moving — so staleness
 * has to be asserted against the clock rather than waiting for a failure.
 *
 * PHASE 2 ADDED A SECOND FAILURE OF THE SAME KIND, and it is the reason this
 * command reads two tables. The nightly Agent job now has two steps: step 1
 * builds dbo.FinanceLedgerSnapshot, step 2 builds
 * dbo.FinanceRequisitionSnapshot. Agent steps cannot share a transaction, so
 * step 1 can succeed while step 2 fails — the summary advances, the detail does
 * not, and a user drilling from one into the other sees figures that disagree.
 *
 * Reading FinanceLedgerRefresh alone would make that COMPLETELY SILENT: the
 * ledger is fresh, the job's own history records a failure nobody reads, and
 * the detail quietly falls a day further behind every day. So this command
 * asserts three things about the requisition snapshot — that it exists, that it
 * is fresh, and that its RefreshedAt is from the SAME RUN as the ledger's.
 * That last one is the only signal that catches a step-2-only failure, and
 * neither table shows it on its own.
 *
 * Returns a NON-ZERO exit code on any of those, so Task Scheduler and
 * scripts/check-ledger-health.ps1 can alert on it.
 */
class LedgerStatus extends Command
{
    protected $signature = 'ledger:status
                            {--max-age-hours=36 : Age at which a snapshot is considered stale}
                            {--max-drift-minutes= : Allowed gap between the ledger and requisition refresh times (default: config)}
                            {--json : Output raw JSON instead of a table}';

    protected $description = 'Report finance ledger and requisition snapshot freshness; exit non-zero if stale';

    public function handle(): int
    {
        $maxAge = (int) $this->option('max-age-hours');
        $maxDrift = (int) ($this->option('max-drift-minutes')
            ?: config('ledger.requisition.max_run_drift_minutes'));

        // ── Ledger ───────────────────────────────────────────────────────────
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

        $ledgerRefreshedAt = $rows->where('Outcome', 'OK')->max('RefreshedAt');

        // ── Requisition detail (Phase 2) ─────────────────────────────────────
        $req = $this->requisitionState($ledgerRefreshedAt, $maxAge);

        // ── Output ───────────────────────────────────────────────────────────
        if ($this->option('json')) {
            $this->line(json_encode([
                'currentFiscalYear' => $currentFy,
                'refreshedAt' => $current->RefreshedAt ?? null,
                'ageHours' => $ageHours,
                'maxAgeHours' => $maxAge,
                'rowsLoaded' => $current->RowsLoaded ?? null,
                'abortedYears' => $aborted->pluck('FinancialYear')->all(),
                'stale' => $current === null || $ageHours > $maxAge,
                'requisition' => $req + ['maxDriftMinutes' => $maxDrift],
            ], JSON_PRETTY_PRINT));
        } else {
            $this->table(
                ['FY', 'Refreshed At', 'Rows', 'Secs', 'Outcome', 'Message'],
                $rows->map(fn ($r) => [
                    $r->FinancialYear, $r->RefreshedAt, $r->RowsLoaded,
                    $r->DurationSeconds, $r->Outcome, $r->Message,
                ])->all()
            );

            $this->line($req['configured']
                ? sprintf(
                    'Requisition detail: %s rows, refreshed %s (%sh old), outcome %s, drift %s min.',
                    number_format((int) $req['rowsLoaded']),
                    $req['refreshedAt'] ?? 'never',
                    $req['ageHours'] ?? '?',
                    $req['outcome'] ?? '?',
                    $req['driftMinutes'] ?? '?',
                )
                : 'Requisition detail: not configured on this database.');
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

        // Phase 2 verdicts come BEFORE the ledger's aborted-year warning: a
        // detail page disagreeing with the summary it drills into is worse than
        // one fiscal year holding its previous good snapshot on purpose.
        if ($req['configured']) {
            if ($req['refreshedAt'] === null) {
                $this->error('CRITICAL: the requisition snapshot has never been built successfully. Run: php artisan requisition:refresh');

                return self::FAILURE;
            }

            if ($req['ageHours'] > $maxAge) {
                $this->error("CRITICAL: the requisition snapshot is {$req['ageHours']}h old (limit {$maxAge}h). Step 2 of the Agent job is probably failing — check msdb.dbo.sysjobhistory.");

                return self::FAILURE;
            }

            // ABORTED is checked BEFORE drift, because an abort is the CAUSE and
            // drift the symptom: a run that keeps aborting stops advancing
            // RefreshedAt, so the two snapshots pull apart a day at a time.
            // Reporting drift first would send someone to check a job step that
            // ran perfectly well and failed a gate on purpose — the answer is
            // in the Message, not in sysjobhistory.
            if ($req['outcome'] !== 'OK') {
                $this->warn('WARNING: the last requisition refresh ABORTED. Previous snapshot retained. Reason: '.($req['message'] ?: 'see dbo.FinanceRequisitionRefresh'));

                if ($req['driftMinutes'] !== null && $req['driftMinutes'] > $maxDrift) {
                    $this->warn("The snapshots are also {$req['driftMinutes']} minutes apart (limit {$maxDrift}) — a consequence of the above, not a separate fault. Resolve the abort and they realign.");
                }

                return self::FAILURE;
            }

            if ($req['driftMinutes'] !== null && $req['driftMinutes'] > $maxDrift) {
                // The step-2-only failure, and the reason this command reads two
                // tables at all. Both snapshots can look individually fresh
                // while being from different nights.
                $this->error("CRITICAL: the ledger and requisition snapshots are {$req['driftMinutes']} minutes apart (limit {$maxDrift}). They are not from the same run, so the detail pages disagree with the summary. Check that step 2 of 'SWRHA Finance - Ledger Refresh' is running.");

                return self::FAILURE;
            }

            if ($req['message']) {
                // Observations the refresh records without aborting — stale-year
                // drift, duplicate grain, unparseable account numbers. Not a
                // failure, but the only place they surface routinely.
                $this->warn('NOTE: '.$req['message']);
            }
        } else {
            // Deliberately not a failure. Phase 2 may simply not be deployed
            // here, and this command is also the health check for environments
            // that only ever had Phase 1. Failing would make a not-yet-migrated
            // database indistinguishable from a broken one.
            $this->warn('NOTE: dbo.FinanceRequisitionRefresh is not readable — Phase 2 (requisition detail) is not deployed on this database. Ledger freshness was checked; the detail was not.');
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

    // =========================================================================
    // Requisition snapshot (Phase 2)
    // =========================================================================

    /**
     * The state of dbo.FinanceRequisitionRefresh, or configured => false when
     * the table cannot be read.
     *
     * The log is RUN-KEYED (one appended row per execution, never updated), so
     * "the last run" is the newest row and "the last GOOD run" is the newest
     * row with Outcome = OK. Both matter: freshness is measured against the
     * last good one, but an ABORTED newest row is itself the alert.
     *
     * @return array<string,mixed>
     */
    private function requisitionState(?string $ledgerRefreshedAt, int $maxAge): array
    {
        try {
            $latest = DB::connection('FinanceAutomationSystem')
                ->table('FinanceRequisitionRefresh')
                ->orderByDesc('RunId')
                ->first();

            $lastGood = DB::connection('FinanceAutomationSystem')
                ->table('FinanceRequisitionRefresh')
                ->where('Outcome', 'OK')
                ->orderByDesc('RunId')
                ->first();
        } catch (\Throwable $e) {
            return ['configured' => false, 'error' => $e->getMessage()];
        }

        if ($latest === null) {
            return [
                'configured' => true, 'refreshedAt' => null, 'ageHours' => null,
                'driftMinutes' => null, 'outcome' => null, 'message' => null,
                'rowsLoaded' => 0,
            ];
        }

        // Same signed-diff trap as the ledger age above: operand order is
        // refreshedAt->diff(now()) so a past refresh reads positive.
        $ageHours = $lastGood
            ? round(Carbon::parse($lastGood->RefreshedAt)->diffInHours(now()), 1)
            : null;

        // Absolute, because both directions are wrong in different ways: the
        // requisition lagging means step 2 failed, and the requisition running
        // AHEAD means somebody ran requisition:refresh alone.
        $drift = ($lastGood && $ledgerRefreshedAt)
            ? (int) round(abs(Carbon::parse($ledgerRefreshedAt)->diffInMinutes(Carbon::parse($lastGood->RefreshedAt))))
            : null;

        return [
            'configured' => true,
            'refreshedAt' => $lastGood->RefreshedAt ?? null,
            'ageHours' => $ageHours,
            'driftMinutes' => $drift,
            'outcome' => $latest->Outcome,
            'message' => $latest->Message,
            'rowsLoaded' => $lastGood->RowsLoaded ?? 0,
            'reconMismatches' => $lastGood->ReconMismatches ?? null,
            'staleYearDrift' => $lastGood->ReconStaleYearDrift ?? null,
            'stale' => $ageHours === null || $ageHours > $maxAge,
        ];
    }
}
