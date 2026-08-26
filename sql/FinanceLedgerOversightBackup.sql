/* ===========================================================================
   FinanceLedgerOversightBackup.sql
   ---------------------------------------------------------------------------
   Run BEFORE the Oversight rollout. Preserves everything needed to put the
   ledger back the way it was, in minutes rather than the ~43 minutes a
   full source rebuild would cost.

   Reverting the SQL alone is not enough: the snapshot's Approved/Routing
   figures are rebuilt by the new logic, so restoring the old function without
   the old DATA would leave new figures under an old rule. This script keeps
   both.

   What it preserves:
     dbo.FinanceLedgerSnapshot_PreOversight   every row, all fiscal years
     dbo.FinanceLedgerRefresh_PreOversight    freshness + gate baselines
     dbo.FinanceLedgerDefs_PreOversight       the CREATE text of every object

   NOT preserved here, and needing separate care:
     - the application build (git revert the app commit, then npm run build;
       public/build is gitignored, so there is no artifact to restore);
     - the SQL Agent job (unchanged by this rollout, but disable it for the
       duration - the refresh procs have no sp_getapplock).

   NOT idempotent, deliberately: re-running REFUSES and stops. Once the prepare
   stage has been applied, "current state" is post-change, so a second run would
   capture the very code you might need to roll back. To re-take it on purpose,
   drop all three _PreOversight tables by hand first.
   =========================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* ---- refuse to overwrite a backup that has already served ----------------
   SET NOEXEC ON, not just THROW. THROW aborts only its OWN batch, and every
   GO below starts a new one - so on 2026-08-26 an accidental re-run threw
   correctly, then carried on and rebuilt the definitions table from
   POST-change objects, storing them under a name that says "PreOversight".

   The data survived only because SELECT ... INTO cannot overwrite an existing
   table and errored (Msg 2714). Do not rely on that a second time.

   NOEXEC makes the rest of the script parse but not execute, which is the only
   thing that reliably stops a multi-batch script. It is turned off again at
   the very foot of this file.
   ------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.FinanceLedgerSnapshot_PreOversight', 'U') IS NOT NULL
BEGIN
    DECLARE @existing int = (SELECT COUNT(*) FROM dbo.FinanceLedgerSnapshot_PreOversight);
    PRINT '';
    PRINT '*** REFUSED - NOTHING HAS BEEN CHANGED ***';
    PRINT 'A pre-Oversight backup already exists with ' + CONVERT(varchar(20), @existing) + ' rows.';
    PRINT 'Re-running would overwrite it with CURRENT data - which after the prepare stage is';
    PRINT 'POST-change data, destroying the way back. If you genuinely mean to re-take it, drop';
    PRINT 'all three _PreOversight tables by hand first, as a deliberate decision.';
    PRINT '';
    SET NOEXEC ON;
END
GO

/* ---- 1. the snapshot ----------------------------------------------------- */
SELECT * INTO dbo.FinanceLedgerSnapshot_PreOversight FROM dbo.FinanceLedgerSnapshot;
SELECT * INTO dbo.FinanceLedgerRefresh_PreOversight  FROM dbo.FinanceLedgerRefresh;
GO

/* ---- 2. the object definitions ------------------------------------------- */
/* Belt and braces behind NOEXEC: never drop the captured definitions unless a
   snapshot backup is also absent. On the 2026-08-26 re-run this DROP was what
   actually destroyed something - the guard above had already fired, but the
   batch still executed. */
IF OBJECT_ID('dbo.FinanceLedgerDefs_PreOversight', 'U') IS NOT NULL
   AND OBJECT_ID('dbo.FinanceLedgerSnapshot_PreOversight', 'U') IS NULL
    DROP TABLE dbo.FinanceLedgerDefs_PreOversight;
GO

SELECT
    o.name        AS ObjectName,
    o.type_desc   AS ObjectType,
    m.definition  AS Definition,
    SYSDATETIME() AS CapturedAt
INTO dbo.FinanceLedgerDefs_PreOversight
FROM sys.sql_modules AS m
INNER JOIN sys.objects AS o ON o.object_id = m.object_id
WHERE o.name IN (
    'fn_FinanceLedgerSource',
    'vw_FinanceLedger',
    'vw_WebAppUserAccess',
    'usp_RefreshFinanceLedgerSnapshot',
    'usp_RefreshFinanceLedgerSnapshotAll',
    'MonthlyExpenditure',
    'vw_BudgetAllocation'
);
GO

/* ---- 3. verify, and REPORT rather than assume ---------------------------- */
DECLARE @snapRows int = (SELECT COUNT(*) FROM dbo.FinanceLedgerSnapshot_PreOversight);
DECLARE @defs     int = (SELECT COUNT(*) FROM dbo.FinanceLedgerDefs_PreOversight);

IF @snapRows = 0
    THROW 51211, 'Backup FAILED: the snapshot copy is empty. Do not proceed with the rollout.', 1;

IF @defs < 7
BEGIN
    DECLARE @d nvarchar(300) = N'Backup incomplete: captured ' + CONVERT(nvarchar(10), @defs)
        + N' of 7 object definitions. Check which object is missing before proceeding.';
    THROW 51212, @d, 1;
END
GO

/* Per-FY checksums. A single non-zero total is not proof the copy is good;
   these are what the restore is verified against. Save the output. */
SELECT
    'pre-oversight baseline' AS label,
    FinancialYear,
    COUNT(*)                                  AS accounts,
    CONVERT(decimal(19,2), SUM(Allocation))   AS total_allocation,
    CONVERT(decimal(19,2), SUM(YTDTotal))     AS total_ytd,
    CONVERT(decimal(19,2), SUM(Approved))     AS total_approved,
    CONVERT(decimal(19,2), SUM(Routing))      AS total_routing
FROM dbo.FinanceLedgerSnapshot_PreOversight
GROUP BY FinancialYear
ORDER BY FinancialYear DESC;
GO

/* Per-user accessible totals under the CURRENT (two-way) rule. This is the
   before half of the access comparison - the after half is measured post
   cutover, and every reduction must be explainable by institution scoping. */
SELECT
    'pre-oversight access' AS label,
    ua.UserName,
    COUNT(*)                                AS accounts,
    CONVERT(decimal(19,2), SUM(s.Allocation)) AS allocation
FROM dbo.FinanceLedgerSnapshot_PreOversight AS s
INNER JOIN dbo.vw_WebAppUserAccess AS ua
        ON ua.ResponsibilityID = s.ResponsibilityID
       AND ua.DepartmentID     = s.DepartmentID
WHERE s.FinancialYear = CONVERT(varchar(4), YEAR(SYSDATETIME()) + CASE WHEN MONTH(SYSDATETIME()) >= 10 THEN 1 ELSE 0 END)
GROUP BY ua.UserName
ORDER BY ua.UserName;
GO

PRINT 'Backup complete. Save the result sets above - the restore is verified against them.';
GO

/* Clear the guard so this session is usable again. Harmless when the script
   ran normally; essential when it refused, or every later batch in the same
   SSMS window would silently do nothing. */
SET NOEXEC OFF;
GO
