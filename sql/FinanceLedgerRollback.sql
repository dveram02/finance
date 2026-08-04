/* ===========================================================================
   FinanceLedgerRollback.sql
   ---------------------------------------------------------------------------
   Undoes the finance ledger rollout, in either of two degrees.

   Set the two flags below, then run the whole file. It is idempotent and safe
   to re-run.

     @RestoreLegacyViews = 1   Put dbo.MonthlyExpenditure and
                               dbo.vw_BudgetAllocation back to their original
                               definitions. THIS IS THE URGENT ONE - it is what
                               you run if the cutover misbehaves. Seconds.

     @DropLedgerObjects  = 1   Additionally remove every object the rollout
                               created. Only do this if you are abandoning the
                               work; rebuilding the snapshot afterwards costs
                               16-38 minutes.

   ORDER MATTERS AND THE SCRIPT ENFORCES IT. After cutover the live views are
   defined OVER dbo.vw_FinanceLedger. Dropping the ledger objects first would
   leave dbo.MonthlyExpenditure and dbo.vw_BudgetAllocation pointing at objects
   that no longer exist - the pages would fail, and the legacy definitions
   would be gone. So @DropLedgerObjects REFUSES to run while the cutover is
   still in place.

   Run sql/FinanceLedgerCutover.sql to re-apply the cutover afterwards.
   =========================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;

DECLARE @RestoreLegacyViews bit = 1;
DECLARE @DropLedgerObjects  bit = 0;

/* ---- Report the current state before touching anything ------------------ */
PRINT '--- current state ---';
PRINT 'MonthlyExpenditure          : ' + CASE WHEN OBJECT_ID('dbo.MonthlyExpenditure','V')          IS NULL THEN 'absent' ELSE 'present' END;
PRINT 'MonthlyExpenditure_Legacy   : ' + CASE WHEN OBJECT_ID('dbo.MonthlyExpenditure_Legacy','V')   IS NULL THEN 'absent' ELSE 'present' END;
PRINT 'vw_BudgetAllocation         : ' + CASE WHEN OBJECT_ID('dbo.vw_BudgetAllocation','V')         IS NULL THEN 'absent' ELSE 'present' END;
PRINT 'vw_BudgetAllocation_Legacy  : ' + CASE WHEN OBJECT_ID('dbo.vw_BudgetAllocation_Legacy','V')  IS NULL THEN 'absent' ELSE 'present' END;
PRINT 'vw_FinanceLedger            : ' + CASE WHEN OBJECT_ID('dbo.vw_FinanceLedger','V')            IS NULL THEN 'absent' ELSE 'present' END;
PRINT 'FinanceLedgerSnapshot       : ' + CASE WHEN OBJECT_ID('dbo.FinanceLedgerSnapshot','U')       IS NULL THEN 'absent' ELSE 'present' END;
PRINT '';

/* =========================================================================
   PART 1 - restore the legacy views
   ========================================================================= */
IF @RestoreLegacyViews = 1
BEGIN
    PRINT '--- PART 1: restoring legacy views ---';

    IF OBJECT_ID('dbo.MonthlyExpenditure_Legacy','V') IS NULL
       AND OBJECT_ID('dbo.vw_BudgetAllocation_Legacy','V') IS NULL
    BEGIN
        PRINT 'No _Legacy views found - the cutover was never applied. Nothing to restore.';
    END

    -- Monthly Expenditure
    IF OBJECT_ID('dbo.MonthlyExpenditure_Legacy','V') IS NOT NULL
    BEGIN
        IF OBJECT_ID('dbo.MonthlyExpenditure','V') IS NOT NULL
        BEGIN
            DROP VIEW dbo.MonthlyExpenditure;
            PRINT 'dropped  dbo.MonthlyExpenditure (post-cutover version)';
        END
        EXEC sp_rename 'dbo.MonthlyExpenditure_Legacy', 'MonthlyExpenditure';
        PRINT 'restored dbo.MonthlyExpenditure from _Legacy';
    END

    -- Budget Allocation
    IF OBJECT_ID('dbo.vw_BudgetAllocation_Legacy','V') IS NOT NULL
    BEGIN
        IF OBJECT_ID('dbo.vw_BudgetAllocation','V') IS NOT NULL
        BEGIN
            DROP VIEW dbo.vw_BudgetAllocation;
            PRINT 'dropped  dbo.vw_BudgetAllocation (post-cutover version)';
        END
        EXEC sp_rename 'dbo.vw_BudgetAllocation_Legacy', 'vw_BudgetAllocation';
        PRINT 'restored dbo.vw_BudgetAllocation from _Legacy';
    END

    PRINT '';
END

/* =========================================================================
   PART 2 - remove the ledger objects
   ========================================================================= */
IF @DropLedgerObjects = 1
BEGIN
    PRINT '--- PART 2: dropping ledger objects ---';

    -- GUARD. If a _Legacy view still exists, the cutover has NOT been undone,
    -- which means the live views are still defined over dbo.vw_FinanceLedger.
    -- Dropping it now would break both pages AND destroy the only copy of the
    -- original definitions.
    IF OBJECT_ID('dbo.MonthlyExpenditure_Legacy','V') IS NOT NULL
       OR OBJECT_ID('dbo.vw_BudgetAllocation_Legacy','V') IS NOT NULL
    BEGIN
        THROW 51100, 'REFUSED: the cutover is still in place (a _Legacy view exists). The live views depend on dbo.vw_FinanceLedger, so dropping it now would break them and lose the original definitions. Re-run with @RestoreLegacyViews = 1 first.', 1;
    END

    IF OBJECT_ID('dbo.vw_FinanceLedger','V') IS NOT NULL
    BEGIN DROP VIEW dbo.vw_FinanceLedger;                            PRINT 'dropped  dbo.vw_FinanceLedger'; END

    IF OBJECT_ID('dbo.vw_WebAppUserAccess','V') IS NOT NULL
    BEGIN DROP VIEW dbo.vw_WebAppUserAccess;                         PRINT 'dropped  dbo.vw_WebAppUserAccess'; END

    IF OBJECT_ID('dbo.usp_RefreshFinanceLedgerSnapshotAll','P') IS NOT NULL
    BEGIN DROP PROCEDURE dbo.usp_RefreshFinanceLedgerSnapshotAll;    PRINT 'dropped  dbo.usp_RefreshFinanceLedgerSnapshotAll'; END

    IF OBJECT_ID('dbo.usp_RefreshFinanceLedgerSnapshot','P') IS NOT NULL
    BEGIN DROP PROCEDURE dbo.usp_RefreshFinanceLedgerSnapshot;       PRINT 'dropped  dbo.usp_RefreshFinanceLedgerSnapshot'; END

    IF OBJECT_ID('dbo.fn_FinanceLedgerSource','IF') IS NOT NULL
    BEGIN DROP FUNCTION dbo.fn_FinanceLedgerSource;                  PRINT 'dropped  dbo.fn_FinanceLedgerSource'; END

    IF OBJECT_ID('dbo.FinanceLedgerSnapshot_Staging','U') IS NOT NULL
    BEGIN DROP TABLE dbo.FinanceLedgerSnapshot_Staging;              PRINT 'dropped  dbo.FinanceLedgerSnapshot_Staging'; END

    IF OBJECT_ID('dbo.FinanceLedgerSnapshot','U') IS NOT NULL
    BEGIN DROP TABLE dbo.FinanceLedgerSnapshot;                      PRINT 'dropped  dbo.FinanceLedgerSnapshot'; END

    IF OBJECT_ID('dbo.FinanceLedgerRefresh','U') IS NOT NULL
    BEGIN DROP TABLE dbo.FinanceLedgerRefresh;                       PRINT 'dropped  dbo.FinanceLedgerRefresh'; END

    PRINT '';
END

/* ---- Report the resulting state ----------------------------------------- */
PRINT '--- resulting state ---';
PRINT 'MonthlyExpenditure          : ' + CASE WHEN OBJECT_ID('dbo.MonthlyExpenditure','V')          IS NULL THEN 'absent' ELSE 'present' END;
PRINT 'MonthlyExpenditure_Legacy   : ' + CASE WHEN OBJECT_ID('dbo.MonthlyExpenditure_Legacy','V')   IS NULL THEN 'absent' ELSE 'present' END;
PRINT 'vw_BudgetAllocation         : ' + CASE WHEN OBJECT_ID('dbo.vw_BudgetAllocation','V')         IS NULL THEN 'absent' ELSE 'present' END;
PRINT 'vw_BudgetAllocation_Legacy  : ' + CASE WHEN OBJECT_ID('dbo.vw_BudgetAllocation_Legacy','V')  IS NULL THEN 'absent' ELSE 'present' END;
PRINT 'vw_FinanceLedger            : ' + CASE WHEN OBJECT_ID('dbo.vw_FinanceLedger','V')            IS NULL THEN 'absent' ELSE 'present' END;
PRINT 'FinanceLedgerSnapshot       : ' + CASE WHEN OBJECT_ID('dbo.FinanceLedgerSnapshot','U')       IS NULL THEN 'absent' ELSE 'present' END;

/* ===========================================================================
   AFTER A PART 1 ROLLBACK

   The application keeps working - the two view names and their column lists
   are unchanged, so the models do not care which definition is behind them.
   You are simply back to the old (slow) Monthly Expenditure.

   The ledger objects are left intact, so re-applying is just:
       sql/FinanceLedgerCutover.sql
   No rebuild needed unless you also ran PART 2.
   =========================================================================== */
