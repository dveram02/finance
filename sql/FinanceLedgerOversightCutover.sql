/* ===========================================================================
   FinanceLedgerOversightCutover.sql
   ---------------------------------------------------------------------------
   The user-visible half of the 2026-08-25 Oversight rollout: applies
   dbo.vw_WebAppUserAccess and dbo.vw_FinanceLedger TOGETHER, in ONE
   transaction.

   *** WHY ONE TRANSACTION - READ BEFORE SPLITTING THIS UP ***

   0006CWebAppPostControls gained an InstitutionID column, and 32 of its 128
   active (Responsibility, Department) pairs now appear TWICE, differing only
   by institution. That means:

     - the NEW access view (4-tuple DISTINCT) emits two rows for those pairs;
     - the OLD ledger view joins on (Responsibility, Department) only.

   Run the new access view against the old ledger view - even for the seconds
   between two GO batches - and every account under those 32 mappings matches
   TWICE. Every money figure on them DOUBLES, silently, on a live system.

   The reverse order is equally bad: the new ledger view against the old access
   view has no InstitutionID column to join to, so it fails outright.

   Applying both inside one transaction closes the window entirely. DDL is
   transactional in SQL Server; CREATE/ALTER VIEW must be the first statement
   in its batch, which is why each is wrapped in EXEC(N'...').

   RUN ORDER FOR THE OVERSIGHT ROLLOUT
     1. FinanceLedgerOversightBackup.sql      (snapshot + definitions)
     2. FinanceLedgerOversightPrepare.sql     (function, procs, metadata DDL)
     3. rebuild every fiscal year, verify totals and access
     4. THIS SCRIPT + deploy the frontend build   <- the only visible moment
     5. re-enable the SQL Agent job

   Steps 2-3 are invisible to users: the function and procs feed only the
   refresh, so the app keeps serving the OLD rule over progressively updated
   data. This script is where the new rule and the narrowed access go live.

   sql/FinanceLedger.sql remains the full idempotent installer for fresh
   environments and dev. It creates both views too - safe there, because
   nobody is reading between the batches. On a LIVE system use this script.

   ROLLBACK: sql/FinanceLedgerOversightRestore.sql
   =========================================================================== */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET XACT_ABORT ON;
GO

/* ---- guards: refuse to cut over onto a snapshot that is not ready -------- */
IF OBJECT_ID('dbo.FinanceLedgerSnapshot', 'U') IS NULL
    THROW 51200, 'FinanceLedgerSnapshot does not exist. Run sql/FinanceLedger.sql first.', 1;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.FinanceLedgerSnapshot)
    THROW 51201, 'FinanceLedgerSnapshot is empty. Rebuild before cutting over.', 1;
GO

/* The access column must exist, or the new ledger view cannot compile. There
   is deliberately NO fallback to the two-way join: that rule is now known to
   expose other institutions' money, so shipping it would be shipping a defect
   we have already measured. Fail the release instead. */
IF COL_LENGTH('SWRHAExpenseControl.dbo.0006CWebAppPostControls', 'InstitutionID') IS NULL
    THROW 51202, 'ABORT: 0006CWebAppPostControls has no InstitutionID column. The three-way access join cannot be built, and falling back to the two-way join would re-expose cross-institution data. Confirm the source system before releasing.', 1;
GO

/* A blank InstitutionID passes IS NOT NULL and then matches nothing, so the
   user would see an empty application with no error to explain it. */
IF EXISTS (
    SELECT 1 FROM [SWRHAExpenseControl].[dbo].[0006CWebAppPostControls]
    WHERE IsActive = 'TRUE' AND NULLIF(LTRIM(RTRIM(InstitutionID)), '') IS NULL
)
    THROW 51203, 'ABORT: active rows in 0006CWebAppPostControls have a blank or NULL InstitutionID. Those grants would resolve to nothing and the affected users would see an empty application. Populate them first.', 1;
GO

/* ---- the cutover -------------------------------------------------------- */
BEGIN TRANSACTION;

EXEC(N'
CREATE OR ALTER VIEW dbo.vw_WebAppUserAccess
AS
SELECT DISTINCT
    LTRIM(RTRIM(U.UserName))                                             AS UserName,
    UPPER(LTRIM(RTRIM(P.InstitutionID)))    COLLATE Latin1_General_CI_AS AS InstitutionID,
    UPPER(LTRIM(RTRIM(P.ResponsibilityID))) COLLATE Latin1_General_CI_AS AS ResponsibilityID,
    UPPER(LTRIM(RTRIM(P.DepartmentID)))     COLLATE Latin1_General_CI_AS AS DepartmentID
FROM [SWRHAExpenseControl].[dbo].[0006AWebAppControls] AS U
INNER JOIN [SWRHAExpenseControl].[dbo].[0006CWebAppPostControls] AS P
    ON U.PositionID = P.PositionID
WHERE U.IsActive = ''TRUE''
  AND P.IsActive = ''TRUE''
  AND NULLIF(LTRIM(RTRIM(U.UserName)),         '''') IS NOT NULL
  AND NULLIF(LTRIM(RTRIM(P.InstitutionID)),    '''') IS NOT NULL
  AND NULLIF(LTRIM(RTRIM(P.ResponsibilityID)), '''') IS NOT NULL
  AND NULLIF(LTRIM(RTRIM(P.DepartmentID)),     '''') IS NOT NULL;
');

EXEC(N'
CREATE OR ALTER VIEW dbo.vw_FinanceLedger
AS
SELECT
    s.FinancialYear,
    ua.UserName,
    s.AccountNumber,
    s.AccountDescription,
    s.InstitutionID,
    s.ResponsibilityID,
    s.DepartmentID,
    s.ClusterName,
    s.InstitutionName,
    s.ResponsibilityName,
    s.ResponsibilityName AS Responsibility,   -- Monthly Expenditure binds this name
    s.DepartmentName,
    s.LineNumber,
    s.LineDescription,
    s.MainGroup,
    s.SubGroupA,
    s.SubGroupB,
    s.[Oct], s.[Nov], s.[Dec], s.[Jan], s.[Feb], s.[Mar],
    s.[Apr], s.[May], s.[Jun], s.[Jul], s.[Aug], s.[Sep],
    s.Q1, s.Q2, s.Q3, s.Q4,
    s.YTDTotal,
    s.Approved,
    s.Routing,
    s.Allocation,
    CONVERT(decimal(19,4), s.YTDTotal + s.Approved) AS ActualExpenditure,
    CASE WHEN s.YTDTotal > s.Allocation
         THEN s.YTDTotal - s.Allocation
         ELSE CONVERT(decimal(19,4), 0) END AS Excess,
    CASE WHEN s.Allocation > s.YTDTotal
         THEN s.Allocation - s.YTDTotal
         ELSE CONVERT(decimal(19,4), 0) END AS AllocationBalance
FROM dbo.FinanceLedgerSnapshot AS s
INNER JOIN dbo.vw_WebAppUserAccess AS ua
    ON ua.InstitutionID    = s.InstitutionID
   AND ua.ResponsibilityID = s.ResponsibilityID
   AND ua.DepartmentID     = s.DepartmentID;
');

COMMIT TRANSACTION;
GO

/* ---- post-cutover verification (run and READ these) --------------------- */

/* 1. Nobody should drop to zero. A large REDUCTION is expected and correct -
      it is the cross-institution exposure being closed - but zero means the
      join is broken, and that is a rollback trigger. */
SELECT 'accessible accounts by user' AS check_name, ua.UserName, COUNT(*) AS accounts
FROM dbo.FinanceLedgerSnapshot AS s
INNER JOIN dbo.vw_WebAppUserAccess AS ua
        ON ua.InstitutionID = s.InstitutionID
       AND ua.ResponsibilityID = s.ResponsibilityID
       AND ua.DepartmentID = s.DepartmentID
GROUP BY ua.UserName
ORDER BY accounts;
GO

/* 2. Fan-out check. Any row here means the DISTINCT is not covering the full
      tuple and money is being double-counted. Must return NOTHING. */
SELECT TOP 10 'FAN-OUT - money is doubling' AS alert, FinancialYear, UserName, AccountNumber, COUNT(*) AS times_matched
FROM dbo.vw_FinanceLedger
GROUP BY FinancialYear, UserName, AccountNumber
HAVING COUNT(*) > 1;
GO

/* 3. The balance rule holds on every row. All four counters must be 0. */
SELECT
    'balance rule' AS check_name,
    SUM(CASE WHEN ABS(ActualExpenditure - (YTDTotal + Approved)) > 0.005 THEN 1 ELSE 0 END) AS bad_actual,
    SUM(CASE WHEN Excess > 0 AND AllocationBalance > 0 THEN 1 ELSE 0 END)                   AS both_non_zero,
    SUM(CASE WHEN Excess < 0 OR AllocationBalance < 0 THEN 1 ELSE 0 END)                    AS negatives,
    SUM(CASE WHEN Allocation > YTDTotal
              AND ABS(AllocationBalance - (Allocation - YTDTotal)) > 0.005 THEN 1 ELSE 0 END) AS bad_balance
FROM dbo.vw_FinanceLedger;
GO
