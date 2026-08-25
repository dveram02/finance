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

   Idempotent: re-running REPLACES the backup with current state. Do NOT
   re-run it after the cutover, or you will overwrite the pre-change copy
   with post-change data and lose the way back.
   =========================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* ---- refuse to overwrite a backup that has already served ---------------- */
IF OBJECT_ID('dbo.FinanceLedgerSnapshot_PreOversight', 'U') IS NOT NULL
BEGIN
    DECLARE @existing int = (SELECT COUNT(*) FROM dbo.FinanceLedgerSnapshot_PreOversight);
    DECLARE @msg nvarchar(400) = N'A pre-Oversight backup already exists with '
        + CONVERT(nvarchar(20), @existing) + N' rows. Re-running would overwrite it with '
        + N'CURRENT data - which after a cutover is post-change data, destroying the way back. '
        + N'Drop the _PreOversight tables deliberately if you really mean to re-take it.';
    THROW 51210, @msg, 1;
END
GO

/* ---- 1. the snapshot ----------------------------------------------------- */
SELECT * INTO dbo.FinanceLedgerSnapshot_PreOversight FROM dbo.FinanceLedgerSnapshot;
SELECT * INTO dbo.FinanceLedgerRefresh_PreOversight  FROM dbo.FinanceLedgerRefresh;
GO

/* ---- 2. the object definitions ------------------------------------------- */
IF OBJECT_ID('dbo.FinanceLedgerDefs_PreOversight', 'U') IS NOT NULL
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
