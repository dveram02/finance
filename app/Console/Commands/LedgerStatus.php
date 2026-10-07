<?php

namespace App\Console\Commands;

use App\Support\CurrentYearGrace;
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
                            {--max-age-hours= : Age at which a snapshot is considered stale; defaults to ledger.requisition.max_age_hours}
                            {--max-drift-minutes= : Allowed gap between the ledger and requisition refresh times (default: config)}
                            {--current-year-grace-days= : Days into a new fiscal year that a MISSING current year is tolerated while the source holds no rows for it; defaults to ledger.requisition.current_year_grace_days, 0 disables}
                            {--json : Output raw JSON instead of a table}';

    protected $description = 'Report finance ledger and requisition snapshot freshness; exit non-zero if stale';

    public function handle(): int
    {
        // Default from CONFIG, not a literal here. The two requisition detail
        // pages surface staleness in their context strip and must call it stale
        // at exactly the same age — a page that reassures a user while this
        // command is alerting is worse than either signal alone.
        $maxAge = (int) ($this->option('max-age-hours')
            ?: config('ledger.requisition.max_age_hours'));
        $maxDrift = (int) ($this->option('max-drift-minutes')
            ?: config('ledger.requisition.max_run_drift_minutes'));
        // `??`, not `?:` — an explicit `--current-year-grace-days=0` must mean
        // ZERO (restore the unconditional CRITICAL), not "fall back to config".
        $graceDays = (int) ($this->option('current-year-grace-days')
            ?? config('ledger.requisition.current_year_grace_days'));

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

        // A MISSING current fiscal year is not automatically a failure, and
        // getting this wrong is how monitoring dies. The refresh enumerates
        // fiscal years FROM THE SOURCE, not from a calendar range, so a year
        // that has started but holds no source rows yet is never attempted and
        // never logged — while this command derives the current year from the
        // clock. Measured 2026-10-07, one day after go-live: FY2027 had zero
        // rows in both source tables and this command reported CRITICAL while
        // the nightly job had run correctly.
        //
        // So the absence is benign only when BOTH hold: the source genuinely
        // has nothing for that year, AND the year is still inside the grace
        // window. Past the window it means nobody loaded the allocations, which
        // is a real problem that would otherwise never surface.
        //
        // 🔴 Fails CLOSED: if the source probe itself throws, sourceRows is
        // null and the year is treated as a genuine failure. "We could not
        // establish that this is benign" must never read as benign.
        $currentFyExpectedEmpty = false;
        $currentFySourceRows = null;

        if ($current === null) {
            $currentFySourceRows = $this->sourceRowCountForYear($currentFy);
            $currentFyExpectedEmpty = CurrentYearGrace::isExpectedlyAbsent(
                $currentFySourceRows,
                CurrentYearGrace::ageInDays($currentFy),
                $graceDays,
            );
        }

        // What freshness is actually asserted against. Normally the current
        // year; when that year is legitimately absent, the newest year that WAS
        // built — otherwise skipping the check would also skip the stopped-
        // scheduler detection, which is the whole point of this command.
        $assertedAgeHours = $ageHours;
        $assertedLabel = "FY{$currentFy}";

        if ($current === null && $currentFyExpectedEmpty) {
            $assertedAgeHours = $ledgerRefreshedAt
                ? round(Carbon::parse($ledgerRefreshedAt)->diffInHours(now()), 1)
                : null;
            $assertedLabel = 'the newest built fiscal year';
        }

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
                // `stale` follows the ASSERTED age, so a legitimately absent
                // current year does not report stale while the newest built
                // year is fresh. The three fields below are what let a consumer
                // tell that case apart from a real gap.
                'stale' => $assertedAgeHours === null || $assertedAgeHours > $maxAge,
                'assertedAgainst' => $assertedLabel,
                'assertedAgeHours' => $assertedAgeHours,
                'currentFiscalYearMissingButExpected' => $currentFyExpectedEmpty,
                'currentFiscalYearSourceRows' => $currentFySourceRows,
                'currentYearGraceDays' => $graceDays,
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
        if ($current === null && ! $currentFyExpectedEmpty) {
            $this->error($currentFySourceRows === null
                ? "CRITICAL: fiscal year {$currentFy} has never been built, and the source could not be checked to establish whether that is expected."
                : "CRITICAL: fiscal year {$currentFy} has never been built, and the source holds {$currentFySourceRows} row(s) for it. Run: php artisan ledger:refresh --year={$currentFy}");

            return self::FAILURE;
        }

        if ($current === null) {
            // Benign, but SAY SO on every run. A silently skipped assertion is
            // indistinguishable from a passing one, and this is the line that
            // explains why the table has no row for the current year.
            $this->warn("FY{$currentFy} has not been built, and the source holds no rows for it yet — expected this early in a fiscal year (grace {$graceDays} days). Freshness asserted against the newest built year instead.");
        }

        if ($assertedAgeHours === null) {
            $this->error('CRITICAL: no fiscal year has a successful refresh. Run: php artisan ledger:refresh --all');

            return self::FAILURE;
        }

        if ($assertedAgeHours > $maxAge) {
            $this->error("CRITICAL: {$assertedLabel} snapshot is {$assertedAgeHours}h old (limit {$maxAge}h). The scheduler is probably not running.");

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

        // $current may legitimately be null here — a brand-new fiscal year with
        // no source data yet, which the verdict above reported as expected. The
        // success line therefore has two shapes rather than dereferencing it.
        $this->info($current !== null
            ? "OK: FY{$currentFy} snapshot is {$ageHours}h old ({$current->RowsLoaded} rows)."
            : "OK: {$assertedLabel} snapshot is {$assertedAgeHours}h old. FY{$currentFy} is not built yet and has no source data — see the note above.");

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
    /**
     * How many source rows exist for a fiscal year — null if it cannot be read.
     *
     * This mirrors the year enumeration inside
     * usp_RefreshFinanceLedgerSnapshotAll, which builds its list from
     * 0098AFinGLMaster UNION 0040CBudgetsAllocation. That is WHY a started-but-
     * dataless fiscal year is never built: it is not in the source, so it is
     * never in the list. Keep the two in step — if the proc's enumeration ever
     * gains a third table, this must gain it too, or this command will call a
     * genuinely missing year "expected".
     *
     * 🔴 Returns NULL on any error rather than 0. A failed probe must never be
     * mistaken for "the year is legitimately empty" — that would turn the
     * stopped-scheduler alarm off on the strength of a connection blip. The
     * caller treats null as a genuine failure.
     *
     * Both tables are PRE-EXISTING and belong to other systems: this reads
     * them and nothing more.
     */
    private function sourceRowCountForYear(string $fy): ?int
    {
        try {
            $db = DB::connection('FinanceAutomationSystem');

            $gl = (int) $db->table('0098AFinGLMaster')
                ->where('FinancialYear', $fy)
                ->count();

            if ($gl > 0) {
                return $gl;
            }

            return $gl + (int) $db->table('0040CBudgetsAllocation')
                ->where('FinancialYear', $fy)
                ->count();
        } catch (\Throwable $e) {
            return null;
        }
    }

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
