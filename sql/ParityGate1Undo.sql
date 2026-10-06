/* ===========================================================================
   ParityGate1Undo.sql
   ---------------------------------------------------------------------------
   Undoes everything the September-update runbook does up to and including
   GATE 1 (steps 0.2 through 1.4). Run on PRODUCTION in SSMS.

   WHAT PHASE 1 ACTUALLY DID, AND WHY THIS IS SAFE
     Steps 1.1 and 1.3 create three FUNCTIONS and nothing else - verified
     against the scripts: ParityVerbatimDraft.sql has two CREATE OR ALTER
     FUNCTION statements, FinanceLedgerAccessParity.sql has one. No table was
     created, altered or written; no live object was replaced. Nothing in the
     request path references any of the three, so dropping them cannot affect
     the portal.

     Step 1.4 (ParityReconciliation_Gate1.sql) and the two Gate1Diagnose_*
     scripts are read-only and create only #temp tables, which vanished when
     the session closed. There is nothing to undo for those.

     THE ONE THING WITH OPERATIONAL CONSEQUENCE IS STEP 0.2 - it DISABLED the
     Agent job. Left disabled, both snapshots silently go stale and nothing
     alerts, because the production health-check task has never been
     registered. Section 2 below is therefore the part that matters.

   NOT TOUCHED BY THIS SCRIPT, because Phase 1 never reached them:
     dbo.FinanceLedgerSnapshot / FinanceRequisitionSnapshot   (unchanged)
     dbo.fn_FinanceLedgerSource                               (still pre-parity)
     usp_RefreshFinanceLedgerSnapshot / usp_RefreshFinanceRequisition
     AccountID / AccountsLoaded / SplitAccountCount           (never added)
     the *_ParityBackup tables                                (never created)
   =========================================================================== */

USE FinanceAutomationSystem;
SET NOCOUNT ON;
GO

/* --- 1. Confirm nothing beyond Phase 1 was reached ------------------------
   Run this FIRST. If any value is not as stated, STOP and do not continue -
   the deployment got further than Phase 1 and needs the runbook's own
   rollback (sql/FinanceLedgerParityCutover.sql / the _ParityBackup restore),
   not this script. */

SELECT 'PRE_UNDO_STATE' AS chk,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('dbo.fn_FinanceLedgerSource')) LIKE '%draftCorr%'
            THEN 'PARITY - STOP' ELSE 'pre-parity (expected)' END            AS ledger_fn,
       CASE WHEN COL_LENGTH('dbo.FinanceLedgerSnapshot','AccountID') IS NULL
            THEN 'absent (expected)' ELSE 'present - STOP' END               AS accountid_col,
       CASE WHEN OBJECT_ID('dbo.FinanceLedgerSnapshot_ParityBackup') IS NULL
            THEN 'absent (expected)' ELSE 'present - Phase 2 ran' END        AS ledger_backup,
       CASE WHEN OBJECT_ID('dbo.FinanceRequisitionSnapshot_ParityBackup') IS NULL
            THEN 'absent (expected)' ELSE 'present - Phase 2 ran' END        AS req_backup,
       (SELECT COUNT(*) FROM dbo.FinanceLedgerSnapshot WHERE FinancialYear = '2026') AS fy2026_rows,
       (SELECT CONVERT(decimal(19,2), SUM(Approved)) FROM dbo.FinanceLedgerSnapshot
         WHERE FinancialYear = '2026')                                        AS fy2026_approved;

/* The snapshot figures above should be whatever production served before you
   started - the pre-parity values. Phase 1 cannot have moved them; this is a
   witness, not a gate. */
GO

/* --- 2. RE-ENABLE THE AGENT JOB (undoes step 0.2) ------------------------
   Do this whether or not you drop the functions below. A disabled job is the
   only lasting change Phase 1 made to how production behaves. */

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'SWRHA Finance - Ledger Refresh')
    EXEC msdb.dbo.sp_update_job
         @job_name = N'SWRHA Finance - Ledger Refresh',
         @enabled  = 1;

SELECT 'AGENT_JOB' AS chk, name, enabled
FROM msdb.dbo.sysjobs
WHERE name = N'SWRHA Finance - Ledger Refresh';

/* PASS: enabled = 1. If NO ROWS come back, the job is not on this instance -
   on production that is itself a finding: stop and establish where the
   nightly refresh actually runs from before going any further. */
GO

/* --- 3. Drop the three scratch functions (undoes steps 1.1 and 1.3) ------
   Optional. Keep them if you intend to re-run GATE 1 - they are inert and
   read-only, nothing in the app or the refresh path references them. Drop
   them if you want production carrying no trace of the attempt. */

IF OBJECT_ID('dbo.fn_FinanceLedgerAccessParity') IS NOT NULL
    DROP FUNCTION dbo.fn_FinanceLedgerAccessParity;

IF OBJECT_ID('dbo.fn_OversightDraftUnscoped') IS NOT NULL
    DROP FUNCTION dbo.fn_OversightDraftUnscoped;

IF OBJECT_ID('dbo.fn_OversightDraftVerbatim') IS NOT NULL
    DROP FUNCTION dbo.fn_OversightDraftVerbatim;
GO

/* --- 4. Verify ----------------------------------------------------------- */

SELECT 'POST_UNDO' AS chk,
       CASE WHEN OBJECT_ID('dbo.fn_FinanceLedgerAccessParity') IS NULL THEN 'dropped' ELSE 'STILL PRESENT' END AS parity_fn,
       CASE WHEN OBJECT_ID('dbo.fn_OversightDraftUnscoped')    IS NULL THEN 'dropped' ELSE 'STILL PRESENT' END AS draft_unscoped,
       CASE WHEN OBJECT_ID('dbo.fn_OversightDraftVerbatim')    IS NULL THEN 'dropped' ELSE 'STILL PRESENT' END AS draft_verbatim,
       CASE WHEN OBJECT_DEFINITION(OBJECT_ID('dbo.fn_FinanceLedgerSource')) LIKE '%draftCorr%'
            THEN 'PARITY - WRONG' ELSE 'pre-parity (correct)' END AS live_ledger_fn,
       (SELECT enabled FROM msdb.dbo.sysjobs WHERE name = N'SWRHA Finance - Ledger Refresh') AS agent_job_enabled;

/* PASS: three 'dropped', live_ledger_fn 'pre-parity (correct)',
         agent_job_enabled 1.

   Production is now exactly as it was before step 0.2, serving pre-parity
   figures, with the nightly refresh running again. */
GO
