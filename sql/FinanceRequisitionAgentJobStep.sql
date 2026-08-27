/* ===========================================================================
   FinanceRequisitionAgentJobStep.sql   -   PHASE 2 scheduling
   ---------------------------------------------------------------------------
   Adds a SECOND STEP to the EXISTING job `SWRHA Finance - Ledger Refresh`.

   *** NOT A SECOND JOB, AND NOT A SECOND SCHEDULE. *** Three reasons, and all
   three are the point of the phase rather than a preference:

     1. Both snapshots must be built from the SAME source state. A separate
        schedule reintroduces exactly the drift this design exists to remove.
     2. The reconciliation gate inside usp_RefreshFinanceRequisition compares
        against dbo.FinanceLedgerSnapshot, so the ledger step must have
        finished first.
     3. Agent prevents overlap by refusing to start a job that is already
        running. Two jobs would have two locks and no relationship between
        them; the procs carry no sp_getapplock.

   And, unchanged from Phase 1: do NOT add a Laravel `Schedule::command()`
   entry for this. Combined with the Agent job it double-schedules the same
   proc, and nothing at the SQL layer prevents two concurrent refreshes.
   `php artisan requisition:refresh` exists for MANUAL runs only.

   This file mirrors sql/FinanceLedgerAgentJob.sql section by section. Where a
   section is absent, the reason is stated rather than left to inference.

     §1  Agent service account   - unchanged, same account as Phase 1
     §2  Linked-server mapping   - NOT NEEDED, see below
     §3  Grants                  - extended
     §4  Linked-server GATE      - NOT NEEDED, see below
     §5  Amend the job           - the two statements that matter
     §6  Start once and verify
     §7  GL load window          - unchanged, same question, same answer
     §8  Rollback

   §2 / §4 ARE NOT NEEDED. The linked-server gates existed solely to protect
   the chart-of-accounts reads, and those moved local on 2026-08-25, retiring
   the gate for Phase 1 as well. Phase 2 reads only local tables
   (0040DBudgetsEncumbrance, 0098FPOShipmentDetails, the 0030A* report tables
   and FinanceLedgerSnapshot), so it never reintroduces the dependency.

   RUN ORDER: sql/FinanceRequisition.sql, then one manual
   `EXEC dbo.usp_RefreshFinanceRequisition;` to prove the build, THEN this.
   Scheduling a proc that has never successfully run once is how a failure
   first becomes visible at 21:30 to nobody.

   ROLLBACK: §8 below, and sql/FinanceRequisitionRollback.sql for the objects.
   =========================================================================== */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET XACT_ABORT ON;
GO


/* ===========================================================================
   SECTION 0 — PREFLIGHT: read the job as it actually is, before changing it
   ---------------------------------------------------------------------------
   financesqlupdatep2.md flagged this as "the one change to the existing job,
   and it is easy to miss", and left it CONFIRMED ON DEV, UNCONFIRMED ON
   PRODUCTION (the VPN was down for the rest of that session).

   RUN THIS FIRST AND READ IT. Run it as an admin login in SSMS on the DB
   server — the app login (`finance`) is unlikely to have msdb rights, so this
   is not something the application side can check for itself.

   EXPECT exactly one row:
       step_id 1, 'Refresh snapshot', on_success_action 1, on_fail_action 2,
       retry_attempts 2, retry_interval 20, database FinanceAutomationSystem

   MORE THAN ONE STEP means someone has already amended the job. STOP — §5
   below assumes step 1 is the only step and appends step 2 after it. Re-read
   this file against what is actually deployed before running anything.
   =========================================================================== */
SELECT s.step_id, s.step_name, s.on_success_action, s.on_fail_action,
       s.retry_attempts, s.retry_interval, s.database_name
FROM msdb.dbo.sysjobs AS j
JOIN msdb.dbo.sysjobsteps AS s ON s.job_id = j.job_id
WHERE j.name = N'SWRHA Finance - Ledger Refresh'
ORDER BY s.step_id;
GO


/* ===========================================================================
   SECTION 3 — Grants for the Agent account         [extends §3 of Phase 1]
   ---------------------------------------------------------------------------
   The job step runs as the SQL Agent service account: the job owner is sa and
   the step is T-SQL, so no proxy is involved. The account is the one already
   identified for Phase 1 — typically NT SERVICE\SQLAgent$SQLEXPRESS.

   The account already holds db_datareader, which covers reading
   0040DBudgetsEncumbrance, 0098FPOShipmentDetails, the 0030A* report tables
   and FinanceLedgerSnapshot. Only the new writable objects need grants.

   Note there is no ALTER grant: the refresh proc uses DELETE, not TRUNCATE,
   precisely so this list stays this short.

   Uncomment and substitute the account name.
   =========================================================================== */
USE FinanceAutomationSystem;
GO

-- GRANT EXECUTE        ON dbo.usp_RefreshFinanceRequisition            TO [NT SERVICE\SQLAgent$SQLEXPRESS];
-- GRANT INSERT, DELETE ON dbo.FinanceRequisitionSnapshot               TO [NT SERVICE\SQLAgent$SQLEXPRESS];
-- GRANT INSERT, DELETE ON dbo.FinanceRequisitionSnapshot_Staging       TO [NT SERVICE\SQLAgent$SQLEXPRESS];
-- GRANT INSERT, DELETE ON dbo.FinanceRequisitionRefresh                TO [NT SERVICE\SQLAgent$SQLEXPRESS];
GO

/* DELETE on the refresh LOG, where Phase 1 grants INSERT, UPDATE. Two
   differences, both following from the run-keyed design:
     - no UPDATE, because a run-keyed log is append-only. A row is never
       revised, so the right cannot be needed and is not granted;
     - DELETE, because the proc trims to the most recent @KeepRuns rows.
   If that trim is ever removed, remove this grant with it.                */


/* ===========================================================================
   SECTION 5 — Amend the job                        [the actual change]
   ---------------------------------------------------------------------------
   TWO statements. 5a is the one that is easy to miss, and without it 5b is a
   step that never runs.
   =========================================================================== */
USE msdb;
GO

/* ---- 5a. Step 1 must CONTINUE, not quit ------------------------------------
   Step 1 was created with @on_success_action = 1 (quit reporting success) at
   sql/FinanceLedgerAgentJob.sql:212, because it was the only step. Left as-is,
   a second step would NEVER RUN — and it would never run SILENTLY: the job
   would report success every night while the requisition snapshot sat frozen
   at whenever it was last built by hand.

   3 = go to the next step.

   Step 1's @on_fail_action = 2 (quit reporting failure) STAYS, and that is
   deliberate: if the ledger build trips a sanity gate, the job quits and the
   requisition step does NOT run. Both snapshots then stay on their previous
   contents TOGETHER, rather than the detail advancing past a summary that did
   not. The reconciliation gate would abort step 2 anyway; quitting is simply
   the clearer failure.
   --------------------------------------------------------------------------- */
EXEC msdb.dbo.sp_update_jobstep
    @job_name = N'SWRHA Finance - Ledger Refresh',
    @step_id  = 1,
    @on_success_action = 3;      -- was 1 (quit with success)
GO

/* ---- 5b. Step 2 -------------------------------------------------------------
   Settings match step 1 exactly — same subsystem, same database, same retry
   policy, same failure action — because there is no reason for them to differ
   and every reason for the two halves of one nightly build to behave alike.

   NO DAY-OF-MONTH BRANCH, and that is the measured difference from step 1.
   Step 1 branches because a per-FY ledger build costs minutes. The whole
   requisition history is ~106k rows and the dominant cost — the shipment
   aggregate — is paid once regardless of how many years are built, so step 2
   rebuilds every year every run. There is no @Year parameter to pass.

   The RAISERROR ... WITH NOWAIT progress line follows step 1's convention: it
   reaches the job history immediately rather than being buffered to the end.
   --------------------------------------------------------------------------- */
EXEC msdb.dbo.sp_add_jobstep
    @job_name   = N'SWRHA Finance - Ledger Refresh',
    @step_name  = N'Refresh requisition detail',
    @subsystem  = N'TSQL',
    @database_name = N'FinanceAutomationSystem',
    @retry_attempts = 2,
    @retry_interval = 20,          -- minutes; transient DB errors
    @on_success_action = 1,        -- quit reporting success (last step)
    @on_fail_action    = 2,        -- quit reporting failure
    @command = N'
SET NOCOUNT ON;
RAISERROR(''Finance requisition detail: full rebuild (all fiscal years).'', 0, 1) WITH NOWAIT;
EXEC dbo.usp_RefreshFinanceRequisition @Force = 0;
';
GO

/* ---- 5c. The schedule -------------------------------------------------------
   UNTOUCHED. Daily 21:30, one schedule, one job. Nothing here changes when the
   job starts; it only changes how much it does once started.

   The added time is small — the requisition build is dominated by the ~47s
   shipment aggregate — so the monthly full-rebuild night still finishes hours
   clear of the 01:15 backup. RE-MEASURE on production after the first run
   rather than trusting that sentence.
   --------------------------------------------------------------------------- */


/* ===========================================================================
   SECTION 6 — Start once and verify
   ---------------------------------------------------------------------------
   Run the job by hand once, then READ all three results. Do not wait for
   21:30 to find out.
   =========================================================================== */

-- EXEC msdb.dbo.sp_start_job @job_name = N'SWRHA Finance - Ledger Refresh';
GO

/* 6a. Both steps ran, and step 2 exists. run_status 1 = succeeded.
       step_id 0 is the job outcome row. */
SELECT TOP (10)
    h.step_id, h.step_name, h.run_status, h.run_date, h.run_time, h.run_duration, h.[message]
FROM msdb.dbo.sysjobhistory AS h
JOIN msdb.dbo.sysjobs       AS j ON j.job_id = h.job_id
WHERE j.name = N'SWRHA Finance - Ledger Refresh'
ORDER BY h.instance_id DESC;
GO

/* 6b. The requisition log's own record of that run. Outcome must be OK, and
       ReconMismatches must be 0 — it cannot be anything else on an OK row,
       because the gate aborts, so what is actually worth reading here is
       ReconStaleYearDrift and the Message. */
SELECT TOP (3) * FROM FinanceAutomationSystem.dbo.FinanceRequisitionRefresh ORDER BY RunId DESC;
GO

/* 6c. *** THE CHECK THIS PHASE ADDS, AND THE ONE NEITHER TABLE SHOWS ALONE ***

   Agent steps cannot share a transaction, so there is one failure mode this
   design cannot remove: step 1 succeeds and step 2 fails. The summary then
   advances and the detail does not, and the two disagree until the next
   successful run.

   That is acceptable — it is visible and self-correcting — but ONLY IF
   MONITORING LOOKS AT BOTH. Before this phase, ledger:status and
   check-ledger-health.ps1 read FinanceLedgerRefresh alone, so a step-2-only
   failure was COMPLETELY SILENT.

   The two RefreshedAt values must be from the SAME RUN. drift_minutes is
   normally under a minute on a nightly run and up to the ledger's full-rebuild
   duration on the 1st. A drift measured in HOURS means step 2 did not run.

   `php artisan ledger:status` asserts exactly this and exits non-zero on it —
   this query is the manual form of that check. */
SELECT
    (SELECT MAX(RefreshedAt) FROM FinanceAutomationSystem.dbo.FinanceLedgerRefresh WHERE Outcome = 'OK')      AS ledger_refreshed_at,
    (SELECT MAX(RefreshedAt) FROM FinanceAutomationSystem.dbo.FinanceRequisitionRefresh WHERE Outcome = 'OK') AS requisition_refreshed_at,
    ABS(DATEDIFF(minute,
        (SELECT MAX(RefreshedAt) FROM FinanceAutomationSystem.dbo.FinanceLedgerRefresh WHERE Outcome = 'OK'),
        (SELECT MAX(RefreshedAt) FROM FinanceAutomationSystem.dbo.FinanceRequisitionRefresh WHERE Outcome = 'OK')
    )) AS drift_minutes;
GO


/* ===========================================================================
   SECTION 7 — The GL load window
   ---------------------------------------------------------------------------
   UNCHANGED, and it is the same question with the same answer. §7 of
   sql/FinanceLedgerAgentJob.sql rests on one assumption: that the external
   process writing dbo.0098AFinGLMaster runs during the business DAY, so a
   21:30 refresh reads a complete table.

   Phase 2 reads dbo.0040DBudgetsEncumbrance instead, but it inherits the
   assumption rather than adding a new one — if the requisition source is
   loaded overnight, the detail sits a day behind, permanently and silently, in
   exactly the way §7 describes for the GL. If that section was never settled
   for Phase 1, it is now owed for two tables rather than one.
   =========================================================================== */


/* ===========================================================================
   SECTION 8 — Rollback
   ---------------------------------------------------------------------------
   Removes step 2 and restores step 1's original success action, leaving the
   job exactly as sql/FinanceLedgerAgentJob.sql creates it.

   ORDER MATTERS. Delete the step FIRST. Setting step 1 back to "quit with
   success" while step 2 still exists leaves an orphaned step that never runs
   and reports nothing — which looks identical to a healthy job.

   This does NOT remove the Phase 2 objects. For those:
   sql/FinanceRequisitionRollback.sql.
   =========================================================================== */

-- USE msdb;
-- GO
-- EXEC msdb.dbo.sp_delete_jobstep
--     @job_name = N'SWRHA Finance - Ledger Refresh',
--     @step_id  = 2;
-- GO
-- EXEC msdb.dbo.sp_update_jobstep
--     @job_name = N'SWRHA Finance - Ledger Refresh',
--     @step_id  = 1,
--     @on_success_action = 1;      -- back to quit reporting success
-- GO
-- /* Then confirm the job is back to one step. */
-- SELECT s.step_id, s.step_name, s.on_success_action, s.on_fail_action
-- FROM msdb.dbo.sysjobs AS j
-- JOIN msdb.dbo.sysjobsteps AS s ON s.job_id = j.job_id
-- WHERE j.name = N'SWRHA Finance - Ledger Refresh'
-- ORDER BY s.step_id;
-- GO
