/* ===========================================================================
   FinanceRequisitionRollback.sql   -   guarded teardown of PHASE 2
   ---------------------------------------------------------------------------
   Removes every object sql/FinanceRequisition.sql created, and nothing else.

   *** PHASE 2 IS PURELY ADDITIVE, WHICH MAKES THIS ROLLBACK UNUSUALLY SAFE. ***

   Unlike sql/FinanceLedgerRollback.sql there is nothing to RESTORE. Phase 2
   modified no pre-existing object and replaced no view; every object it
   touches is new and owned by this project. Phase 1 keeps working with all of
   them gone — the ledger does not read them.

   THE ONE THING THAT IS NOT SELF-CONTAINED is the Agent job. Step 2 lives in
   `SWRHA Finance - Ledger Refresh`, and dropping the proc while the step still
   exists turns a healthy nightly job into one that FAILS every night at 21:30.

   RUN §8 OF sql/FinanceRequisitionAgentJobStep.sql FIRST. Guard 1 below
   refuses to run until you have.

   Two flags, both OFF by default, so an accidental execution does nothing:
       @DropObjects  drops the views, the procedure and the staging table
       @DropData     ALSO drops the snapshot and its refresh log

   @DropObjects alone leaves the DATA in place, and that is the useful setting
   for "back this out and think again": the snapshot is a rebuildable
   derivative, but it is also the only record of what the build produced, and
   the log is the only record of whether it ever reconciled.

   ONE BATCH, no GO. The flags are declared once and every guard sees the same
   values — a two-batch version would need them declared twice and would break
   silently the first time somebody edited only one copy.
   =========================================================================== */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET XACT_ABORT ON;
GO

USE FinanceAutomationSystem;
GO

BEGIN
    DECLARE @DropObjects bit = 0;
    DECLARE @DropData    bit = 0;

    IF @DropObjects = 0 AND @DropData = 0
    BEGIN
        PRINT 'Both flags are 0 — nothing was dropped.';
        PRINT 'Set @DropObjects (and optionally @DropData) at the top of this script and re-run.';
        RETURN;
    END

    /* ---- guard 1: the Agent step must be gone first ---------------------
       Fails CLOSED: if this throws and you are certain step 2 has been
       removed, the likely cause is that you cannot read msdb. Run §0 of
       sql/FinanceRequisitionAgentJobStep.sql as an admin login and confirm by
       eye before touching this guard.                                      */
    IF EXISTS (
        SELECT 1
        FROM msdb.dbo.sysjobs AS j
        JOIN msdb.dbo.sysjobsteps AS s ON s.job_id = j.job_id
        WHERE j.name = N'SWRHA Finance - Ledger Refresh'
          AND s.step_name = N'Refresh requisition detail'
    )
        THROW 51300, 'ABORT: the Agent job still has the ''Refresh requisition detail'' step. Dropping dbo.usp_RefreshFinanceRequisition now would make the nightly job FAIL every night at 21:30. Run section 8 of sql/FinanceRequisitionAgentJobStep.sql first.', 1;

    /* ---- guard 2: nothing else may still be reading these ---------------
       Phase 3 builds controllers over vw_FinanceRequisitionDetail. If those
       are deployed, dropping the view is a 500 on two pages rather than a
       rollback. sys.sql_expression_dependencies cannot see an application, so
       this catches SQL-side dependencies only — confirm the app is on a build
       WITHOUT the Phase 3 pages yourself.                                   */
    IF EXISTS (
        SELECT 1
        FROM sys.sql_expression_dependencies AS d
        WHERE d.referenced_id IN (
            OBJECT_ID('dbo.vw_FinanceRequisitionDetail'),
            OBJECT_ID('dbo.vw_FinanceRequisitionDetailUnscoped'),
            OBJECT_ID('dbo.FinanceRequisitionSnapshot')
        )
          AND d.referencing_id NOT IN (
            OBJECT_ID('dbo.vw_FinanceRequisitionDetail'),
            OBJECT_ID('dbo.vw_FinanceRequisitionDetailUnscoped'),
            OBJECT_ID('dbo.usp_RefreshFinanceRequisition')
        )
    )
    BEGIN
        SELECT OBJECT_NAME(d.referencing_id) AS still_depends_on_phase2,
               OBJECT_NAME(d.referenced_id)  AS depends_on
        FROM sys.sql_expression_dependencies AS d
        WHERE d.referenced_id IN (
            OBJECT_ID('dbo.vw_FinanceRequisitionDetail'),
            OBJECT_ID('dbo.vw_FinanceRequisitionDetailUnscoped'),
            OBJECT_ID('dbo.FinanceRequisitionSnapshot')
        )
          AND d.referencing_id NOT IN (
            OBJECT_ID('dbo.vw_FinanceRequisitionDetail'),
            OBJECT_ID('dbo.vw_FinanceRequisitionDetailUnscoped'),
            OBJECT_ID('dbo.usp_RefreshFinanceRequisition')
        );

        THROW 51301, 'ABORT: a SQL object outside Phase 2 still references these objects — listed above. Resolve that dependency before rolling back.', 1;
    END

    /* ---- record what is about to be destroyed --------------------------
       The refresh log is the only record of whether the snapshot ever
       reconciled. Printing the last runs leaves a trace in the session output
       even when @DropData wipes the table. */
    IF OBJECT_ID('dbo.FinanceRequisitionRefresh', 'U') IS NOT NULL
    BEGIN
        PRINT 'Last recorded requisition refresh runs (for the record):';
        SELECT TOP (3) RunId, RefreshedAt, RowsLoaded, DurationSeconds,
                       TotalApproved, TotalRouting, ReconMismatches, Outcome, [Message]
        FROM dbo.FinanceRequisitionRefresh
        ORDER BY RunId DESC;
    END

    /* ---- teardown: views first, they depend on the table ---------------- */
    IF OBJECT_ID('dbo.vw_FinanceRequisitionDetail', 'V') IS NOT NULL
    BEGIN
        DROP VIEW dbo.vw_FinanceRequisitionDetail;
        PRINT 'Dropped dbo.vw_FinanceRequisitionDetail.';
    END

    IF OBJECT_ID('dbo.vw_FinanceRequisitionDetailUnscoped', 'V') IS NOT NULL
    BEGIN
        DROP VIEW dbo.vw_FinanceRequisitionDetailUnscoped;
        PRINT 'Dropped dbo.vw_FinanceRequisitionDetailUnscoped.';
    END

    IF OBJECT_ID('dbo.usp_RefreshFinanceRequisition', 'P') IS NOT NULL
    BEGIN
        DROP PROCEDURE dbo.usp_RefreshFinanceRequisition;
        PRINT 'Dropped dbo.usp_RefreshFinanceRequisition.';
    END

    /* Staging holds nothing between runs — the proc empties it on both the
       success and the abort path — so it goes with the OBJECTS, not the data. */
    IF OBJECT_ID('dbo.FinanceRequisitionSnapshot_Staging', 'U') IS NOT NULL
    BEGIN
        DROP TABLE dbo.FinanceRequisitionSnapshot_Staging;
        PRINT 'Dropped dbo.FinanceRequisitionSnapshot_Staging.';
    END

    IF @DropData = 1
    BEGIN
        IF OBJECT_ID('dbo.FinanceRequisitionSnapshot', 'U') IS NOT NULL
        BEGIN
            DROP TABLE dbo.FinanceRequisitionSnapshot;
            PRINT 'Dropped dbo.FinanceRequisitionSnapshot.';
        END

        IF OBJECT_ID('dbo.FinanceRequisitionRefresh', 'U') IS NOT NULL
        BEGIN
            DROP TABLE dbo.FinanceRequisitionRefresh;
            PRINT 'Dropped dbo.FinanceRequisitionRefresh.';
        END
    END
    ELSE
    BEGIN
        PRINT 'DATA RETAINED: dbo.FinanceRequisitionSnapshot and dbo.FinanceRequisitionRefresh still exist.';
        PRINT 'Re-running sql/FinanceRequisition.sql recreates the objects around them; the next refresh replaces the data.';
    END
END
GO

/* ---------------------------------------------------------------------------
   WHAT TO DO ON THE APPLICATION SIDE
   ---------------------------------------------------------------------------
   The Phase 2 app changes DEGRADE rather than break when these objects are
   gone, deliberately:

     * `php artisan requisition:refresh` reports that the proc does not exist
       and returns a failure exit code.
     * `php artisan ledger:status` treats a missing or unreadable
       FinanceRequisitionRefresh as "not configured" — a warning, not a hard
       failure — and keeps reporting the ledger's own freshness. See the
       requisition section of App\Console\Commands\LedgerStatus.

   So rolling back the SQL alone leaves the health check working on the half
   that still exists. Reverting the app is a separate, optional step.
   --------------------------------------------------------------------------- */
