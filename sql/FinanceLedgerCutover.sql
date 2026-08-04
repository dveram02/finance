/* ===========================================================================
   FinanceLedgerCutover.sql
   ---------------------------------------------------------------------------
   Repoints dbo.MonthlyExpenditure and dbo.vw_BudgetAllocation at
   dbo.vw_FinanceLedger.

   DO NOT RUN until sql/FinanceLedger.sql has been applied, the snapshot has
   been populated, and reconciliation against the legacy views has passed.

   Both views keep their existing NAMES and COLUMN LISTS, so App\Models\
   MonthlyExpenditure and App\Models\BudgetAllocation need no changes at all
   and neither do their controllers.

   The originals are renamed to _Legacy rather than dropped. Keep them until
   reconciliation has passed in production; the rollback at the foot of this
   file restores them in seconds.

   Reconciled on the replica (FFIGUERA1, FY2025 + FY2026):
     - allocation totals identical, per account and in aggregate;
     - no account present on one side and absent on the other;
     - monthly net change identical, 0 value differences, total 104,222.53
       on both sides;
     - 3 legacy rows not reproduced, all of them months whose transactions
       net to exactly zero - see the WHERE NetChange <> 0 note below.
   =========================================================================== */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* Guard: refuse to cut over onto an empty snapshot. */
IF NOT EXISTS (SELECT 1 FROM dbo.FinanceLedgerSnapshot)
    THROW 51010, 'FinanceLedgerSnapshot is empty. Run EXEC dbo.usp_RefreshFinanceLedgerSnapshotAll before cutting over.', 1;
GO

/* ---- retire the originals (idempotent) ---------------------------------- */
IF OBJECT_ID('dbo.MonthlyExpenditure_Legacy', 'V') IS NULL
   AND OBJECT_ID('dbo.MonthlyExpenditure', 'V') IS NOT NULL
    EXEC sp_rename 'dbo.MonthlyExpenditure', 'MonthlyExpenditure_Legacy';
GO

IF OBJECT_ID('dbo.vw_BudgetAllocation_Legacy', 'V') IS NULL
   AND OBJECT_ID('dbo.vw_BudgetAllocation', 'V') IS NOT NULL
    EXEC sp_rename 'dbo.vw_BudgetAllocation', 'vw_BudgetAllocation_Legacy';
GO

/* ===========================================================================
   dbo.MonthlyExpenditure - UNPIVOT back to one row per account per period
   ---------------------------------------------------------------------------
   Column list is byte-for-byte what the legacy view emitted, so the model,
   the controller's period filter and the Vue table are untouched.

   PeriodID 1 = Oct ... 12 = Sep. TRXPeriod is built as 'OCT, 25' to match
   App\Concerns\ResolvesFiscalYear::fiscalMonthLabels(); periods 1-3 fall in
   the PREVIOUS calendar year, which is why the year expression branches.

   WHERE NetChange <> 0 is required, not cosmetic. The snapshot stores every
   month as ISNULL(...,0), so without it the view would emit 12 rows for every
   account including months with no activity at all - putting every period in
   the Month dropdown regardless of whether anything happened. The legacy view
   emitted no row in that case. The one visible consequence is that a month
   whose transactions net to exactly zero now disappears rather than showing
   0.00; that accounts for all 3 rows the reconciliation flagged.
   =========================================================================== */
CREATE VIEW dbo.MonthlyExpenditure
AS
SELECT
    l.FinancialYear,
    l.UserName,
    l.AccountNumber,
    m.PeriodID,
    m.MonthAbbr + ', ' + RIGHT(CONVERT(varchar(4),
        CASE WHEN m.PeriodID <= 3 THEN CONVERT(int, l.FinancialYear) - 1
             ELSE CONVERT(int, l.FinancialYear) END), 2) AS TRXPeriod,
    l.AccountDescription,
    m.NetChange,
    l.LineNumber,
    l.LineDescription,
    l.MainGroup,
    l.SubGroupA,
    l.SubGroupB,
    l.ClusterName,
    l.InstitutionName,
    l.Responsibility
FROM dbo.vw_FinanceLedger AS l
CROSS APPLY (VALUES
    ( 1, 'OCT', l.[Oct]), ( 2, 'NOV', l.[Nov]), ( 3, 'DEC', l.[Dec]),
    ( 4, 'JAN', l.[Jan]), ( 5, 'FEB', l.[Feb]), ( 6, 'MAR', l.[Mar]),
    ( 7, 'APR', l.[Apr]), ( 8, 'MAY', l.[May]), ( 9, 'JUN', l.[Jun]),
    (10, 'JUL', l.[Jul]), (11, 'AUG', l.[Aug]), (12, 'SEP', l.[Sep])
) AS m (PeriodID, MonthAbbr, NetChange)
WHERE m.NetChange <> 0;
GO

/* ===========================================================================
   dbo.vw_BudgetAllocation - thin projection
   ---------------------------------------------------------------------------
   Same nine columns the page renders today, with Allocation AS
   TotalAllocation. Retires the legacy view's four non-sargable
   LIKE '%' + DeptFilter + '%' joins.

   WHERE Allocation <> 0 preserves the page's meaning. The ledger now carries
   every account with GL, allocation OR encumbrance activity - that is the
   point of the account-base correction, and it is what stops the 1,117
   allocation-only accounts (TTD 21,128,414.88 in FY2026) from being dropped.
   But a Budget Allocations page is a list of things that were BUDGETED;
   admitting accounts with no allocation would pad it with rows reading 0.00.
   =========================================================================== */
CREATE VIEW dbo.vw_BudgetAllocation
AS
SELECT
    l.FinancialYear,
    l.UserName,
    l.ClusterName,
    l.InstitutionName,
    l.ResponsibilityName,
    l.DepartmentName,
    l.AccountDescription,
    l.AccountNumber,
    l.Allocation AS TotalAllocation
FROM dbo.vw_FinanceLedger AS l
WHERE l.Allocation <> 0;
GO

/* ===========================================================================
   ROLLBACK
   ---------------------------------------------------------------------------
   Run sql/FinanceLedgerRollback.sql with:

       @RestoreLegacyViews = 1
       @DropLedgerObjects  = 0

   Seconds. The application keeps working - the view names and column lists are
   unchanged, so you are simply back to the old (slow) Monthly Expenditure. The
   snapshot survives, so re-applying is just this file again, with no rebuild.

   Do NOT hand-write the rollback. The live views are defined OVER
   dbo.vw_FinanceLedger, so dropping objects in the wrong order breaks both
   pages AND destroys the only copy of the original definitions. The rollback
   script enforces the order and refuses the unsafe case.

   CLEANUP, once production has run on the new views long enough to trust
   (at least one period close):
       DROP VIEW dbo.MonthlyExpenditure_Legacy;
       DROP VIEW dbo.vw_BudgetAllocation_Legacy;

   NOTE: after that cleanup the rollback script can no longer restore the old
   views - the _Legacy copies are the only record of them. Keep a scripted copy
   somewhere before dropping them if you want a way back.
   =========================================================================== */
