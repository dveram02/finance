/* ===========================================================================
   FinanceLedger.sql
   ---------------------------------------------------------------------------
   Unified ledger layer for the Finance Automation portal.

   Adopts "SQL Revised Web App.sql" as the single source for Budget
   Allocations, Monthly Expenditure, the Dashboard, Department Expenditure and
   Allocation Line Expenditure.

   Objects created (all in FinanceAutomationSystem):

     dbo.vw_WebAppUserAccess               live view - who may see which dept
     dbo.fn_FinanceLedgerSource(@FY)       inline TVF - the corrected script
     dbo.FinanceLedgerSnapshot             indexed materialisation
     dbo.FinanceLedgerSnapshot_Staging     build target
     dbo.FinanceLedgerRefresh              freshness / outcome metadata
     dbo.vw_FinanceLedger                  the app's read surface
     dbo.usp_RefreshFinanceLedgerSnapshot  refresh one fiscal year
     dbo.usp_RefreshFinanceLedgerSnapshotAll

   This script is idempotent and ASCII-only (SSMS can misread UTF-8 with no
   BOM). It does NOT redefine dbo.MonthlyExpenditure or dbo.vw_BudgetAllocation
   - that is the cutover, in sql/FinanceLedgerCutover.sql, and must not run
   until reconciliation has passed.

   Run order:
     1. sql/FinanceLedger.sql          (this file)
     2. EXEC dbo.usp_RefreshFinanceLedgerSnapshotAll
     3. reconcile against the legacy views
     4. sql/FinanceLedgerCutover.sql

   TIMINGS. Build cost for ONE fiscal year, no user pruning:
     replica  (V165ICTFA0MEL\SQLEXPRESS, max server memory 2048 MB) ... ~93s
     PRODUCTION (sqlapp\SQLEXPRESS, Standard Edition) ............ 74 - 175s
   The production spread is real: that box serves live Access users, and the
   same statement was sampled at both ends. Budget 16-38 minutes for all 13
   fiscal years, and set FINANCE_LEDGER_REFRESH_TIMEOUT accordingly.

   WHERE THE TIME GOES - measured on production, contrary to what an earlier
   version of this header claimed:
     reading the fact tables ..................... ~1s TOTAL
       (glData 0.84s, allocation 0.02s, encumbrance 0.03s, varianceLines 0.01s)
     everything else ............................. the remaining 72s+
   The 6.38M-row scan of 0098AFinGLMaster is NOT the dominant cost, and the
   FinancialYear index is NOT the lever - see the OPTIONAL INDEX section at the
   foot of this file. The cost is in the account-base UNION, the CROSS APPLY
   splitter and the join chain, which remain unprofiled.
   =========================================================================== */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ===========================================================================
   1. dbo.vw_WebAppUserAccess
   ---------------------------------------------------------------------------
   Deliberately a LIVE view, not a refreshed table: the control tables are on
   the same instance and hold a handful of rows, so a permission change takes
   effect on the next request with no refresh to schedule.

   DISTINCT is on the full triple. A user holding two PositionID rows that map
   to the same department would otherwise duplicate every matching account row
   and DOUBLE every money figure on every page.
   =========================================================================== */
CREATE OR ALTER VIEW dbo.vw_WebAppUserAccess
AS
SELECT DISTINCT
    LTRIM(RTRIM(U.UserName))                                        AS UserName,
    UPPER(LTRIM(RTRIM(P.ResponsibilityID))) COLLATE Latin1_General_CI_AS AS ResponsibilityID,
    UPPER(LTRIM(RTRIM(P.DepartmentID)))     COLLATE Latin1_General_CI_AS AS DepartmentID
FROM [SWRHAExpenseControl].[dbo].[0006AWebAppControls] AS U
INNER JOIN [SWRHAExpenseControl].[dbo].[0006CWebAppPostControls] AS P
    ON U.PositionID = P.PositionID
WHERE U.IsActive = 'TRUE'
  AND P.IsActive = 'TRUE'
  AND U.UserName IS NOT NULL
  AND P.ResponsibilityID IS NOT NULL
  AND P.DepartmentID IS NOT NULL;
GO

/* ===========================================================================
   2. dbo.fn_FinanceLedgerSource
   ---------------------------------------------------------------------------
   "SQL Revised Web App.sql", corrected, with the fiscal year as a REQUIRED
   parameter pushed into glData, allocationData and the encumbrance date
   bounds, where it is sargable. Not a nullable "all years" parameter -
   WHERE (@FY IS NULL OR FinancialYear = @FY) is the classic catch-all that
   defeats sargability. Full rebuilds loop the years instead.

   Corrections against the original script, in order of severity:

   (a) Drives from a COMPLETE account base - the UNION of the account numbers
       appearing in GL, allocation and encumbrance - not from glData alone.
       The original LEFT JOINs allocation onto GL, so an account with a budget
       but no GL activity never appears. Measured FY2026 on the replica:
       1,117 such accounts holding TTD 21,128,414.88. Migrating as written
       would silently cut that from the Total Budget KPI.

   (b) User access is NOT hung off the chart of accounts. The original joins
       userControls to coaData segments matched on AccountID, but
       0040CBudgetsAllocation has no AccountID and 0040DBudgetsEncumbrance has
       only GLAccount - so allocation-only and encumbrance-only rows would
       enter the base and then be eliminated by that INNER JOIN, losing the
       same TTD 21.1M one step later. Segments are parsed from the account
       NUMBER instead, and the access join lives in vw_FinanceLedger. A
       missing chart-of-accounts row now costs a label, never a row and never
       money.

   (c) GL00100 is gone entirely. It only enumerated accounts and mapped
       ACTINDX to segments; (b) derives segments from the account number and
       every NAME comes from GL40200 / 0000CSegmentControls / DBA_Clusters.
       That removes one linked-server table, and the one that proved flaky.

   (d) Money is CONVERTed to decimal(19,4) BEFORE aggregating. All three
       source columns (NetChange, Allocation, ExtendedCost) are float.
       Summing floats and rounding afterwards preserves the accumulation
       error; converting first is exact.

   (e) The hardcoded byte offsets - substring(AccountNumber,3,5), (9,3),
       (13,3), (17,4) - are replaced by the CHARINDEX splitter. Those offsets
       assume every account is exactly 1-5-3-3-4, but 15 rows of 6.38M are
       length 26 rather than 27, so a later segment is short and every offset
       past it slides, silently mis-parsing into the WRONG DEPARTMENT.
       NULLIF(...,0) makes a malformed account yield NULL segments, which
       simply fail to match, instead of raising an invalid-length error.

   (f) FORMAT(TRXDate,'MMM') is replaced by MONTH(). FORMAT is a per-row CLR
       call and culture-dependent - under a non-English session language it
       returns abbreviations matching no PIVOT column, producing silent zeros
       rather than an error. Conditional SUM also drops the PIVOT entirely.

   (g) The nvarchar/int join is gone. FinancialYear is nvarchar while the
       original computed FinYear as YEAR(...)+1, an int; int has higher type
       precedence, so every FinancialYear was implicitly converted per row -
       non-sargable, and a hard error the moment a non-numeric year appears.
       Encumbrance is now filtered on sargable DATE bounds instead.

   (h) The trailing ORDER BY is dropped - invalid in a set-returning object
       without TOP. Ordering is the caller's business.

   (i) The category columns are surfaced. varianceLines already computed
       Part1/Part2/Part3; they were simply never selected.

   Naming: segment names come from 0000CSegmentControls.RevisedDescription,
   falling back to GL40200.DSCRIPTN when that is NULL, blank or 'REMOVE', and
   only then to 'UNDEFINED'. AccountDescription comes from 0098AFinGLMaster,
   falling back to the segment-2 name for accounts with no GL activity (which
   is what the legacy vw_BudgetAllocation used for every row).
   =========================================================================== */
CREATE OR ALTER FUNCTION dbo.fn_FinanceLedgerSource
(
    @FinancialYear varchar(10)
)
RETURNS TABLE
AS
RETURN
(
    WITH segControl AS (
        SELECT
            UPPER(LTRIM(RTRIM(SegmentNumber)))      AS SegmentNumber,
            UPPER(LTRIM(RTRIM(SegmentID)))          AS SegmentID,
            UPPER(LTRIM(RTRIM(RevisedDescription))) AS RevisedDescription
        FROM [FinanceAutomationSystem].[dbo].[0000CSegmentControls]
        WHERE SegmentID IS NOT NULL
    ),
    segGP AS (
        SELECT DISTINCT
            UPPER(LTRIM(RTRIM(SGMTNUMB))) COLLATE Latin1_General_CI_AS AS SegmentNumber,
            UPPER(LTRIM(RTRIM(SGMNTID)))  COLLATE Latin1_General_CI_AS AS SegmentID,
            UPPER(LTRIM(RTRIM(DSCRIPTN))) COLLATE Latin1_General_CI_AS AS SegmentDescription
        FROM [GPSWRHA.SWRHA.CO.TT].[SWRHA].[dbo].[GL40200]
        WHERE UPPER(LTRIM(RTRIM(SGMNTID))) <> ''
    ),
    -- RevisedDescription wins; GL40200's own description is the fallback so a
    -- segment marked REMOVE renders a real name rather than UNDEFINED.
    segName AS (
        SELECT
            g.SegmentNumber,
            g.SegmentID,
            COALESCE(
                NULLIF(CASE WHEN c.RevisedDescription = 'REMOVE' THEN NULL ELSE c.RevisedDescription END, ''),
                NULLIF(g.SegmentDescription, ''),
                'UNDEFINED'
            ) AS SegmentName
        FROM segGP AS g
        LEFT JOIN segControl AS c
            ON c.SegmentNumber COLLATE Latin1_General_CI_AS = g.SegmentNumber
           AND c.SegmentID     COLLATE Latin1_General_CI_AS = g.SegmentID
    ),
    clusterLookup AS (
        SELECT
            UPPER(LTRIM(RTRIM([INSTITUTION CODE]))) COLLATE Latin1_General_CI_AS AS InstitutionCode,
            UPPER(LTRIM(RTRIM(CLUSTER)))            COLLATE Latin1_General_CI_AS AS ClusterName
        FROM [GPSWRHA.SWRHA.CO.TT].[SWRHA].[dbo].[DBA_Clusters]
    ),
    -- Reporting line 3: the 41 goods-and-services account codes. Payroll is
    -- excluded by design - see CLAUDE.md. Verified 41 rows / 41 distinct
    -- accounts on the replica, so this INNER JOIN cannot fan out.
    varianceLines AS (
        SELECT
            CAST(C.AccountNumber AS varchar(50)) COLLATE Latin1_General_CI_AS AS AccountSeg,
            B.LineNumber,
            B.LineDescription,
            LTRIM(RTRIM(PARSENAME(REPLACE(REPLACE(B.LineDescription, '.', ' '), ' : ', ' . '), (LEN(B.LineDescription) - LEN(REPLACE(B.LineDescription, ':', '')) + 1)))) AS MainGroup,
            LTRIM(RTRIM(PARSENAME(REPLACE(REPLACE(B.LineDescription, '.', ' '), ' : ', ' . '), (LEN(B.LineDescription) - LEN(REPLACE(B.LineDescription, ':', '')))))) AS SubGroupA,
            LTRIM(RTRIM(PARSENAME(REPLACE(REPLACE(B.LineDescription, '.', ' '), ' : ', ' . '), (LEN(B.LineDescription) - LEN(REPLACE(B.LineDescription, ':', '')) - 1)))) AS SubGroupB
        FROM [FinanceAutomationSystem].[dbo].[0030AACOAReports] AS A
        INNER JOIN [FinanceAutomationSystem].[dbo].[0030ABCOAReportlines] AS B
            ON A.LineID = B.ReportID
        INNER JOIN [FinanceAutomationSystem].[dbo].[0030ACCOAReportAccounts] AS C
            ON B.LineNumber = C.ReportingLineID
        WHERE A.LineID = 3
          AND B.LineDescription NOT LIKE '%TOTAL%'
    ),
    glData AS (
        SELECT
            UPPER(LTRIM(RTRIM(g.AccountNumber))) COLLATE Latin1_General_CI_AS AS AccountNumber,
            MAX(g.AccountDescription) AS AccountDescription,
            SUM(CASE WHEN MONTH(g.TRXDate) = 10 THEN CONVERT(decimal(19,4), g.NetChange) ELSE 0 END) AS [Oct],
            SUM(CASE WHEN MONTH(g.TRXDate) = 11 THEN CONVERT(decimal(19,4), g.NetChange) ELSE 0 END) AS [Nov],
            SUM(CASE WHEN MONTH(g.TRXDate) = 12 THEN CONVERT(decimal(19,4), g.NetChange) ELSE 0 END) AS [Dec],
            SUM(CASE WHEN MONTH(g.TRXDate) =  1 THEN CONVERT(decimal(19,4), g.NetChange) ELSE 0 END) AS [Jan],
            SUM(CASE WHEN MONTH(g.TRXDate) =  2 THEN CONVERT(decimal(19,4), g.NetChange) ELSE 0 END) AS [Feb],
            SUM(CASE WHEN MONTH(g.TRXDate) =  3 THEN CONVERT(decimal(19,4), g.NetChange) ELSE 0 END) AS [Mar],
            SUM(CASE WHEN MONTH(g.TRXDate) =  4 THEN CONVERT(decimal(19,4), g.NetChange) ELSE 0 END) AS [Apr],
            SUM(CASE WHEN MONTH(g.TRXDate) =  5 THEN CONVERT(decimal(19,4), g.NetChange) ELSE 0 END) AS [May],
            SUM(CASE WHEN MONTH(g.TRXDate) =  6 THEN CONVERT(decimal(19,4), g.NetChange) ELSE 0 END) AS [Jun],
            SUM(CASE WHEN MONTH(g.TRXDate) =  7 THEN CONVERT(decimal(19,4), g.NetChange) ELSE 0 END) AS [Jul],
            SUM(CASE WHEN MONTH(g.TRXDate) =  8 THEN CONVERT(decimal(19,4), g.NetChange) ELSE 0 END) AS [Aug],
            SUM(CASE WHEN MONTH(g.TRXDate) =  9 THEN CONVERT(decimal(19,4), g.NetChange) ELSE 0 END) AS [Sep]
        FROM [FinanceAutomationSystem].[dbo].[0098AFinGLMaster] AS g
        WHERE g.FinancialYear = @FinancialYear
          AND g.TRXDate IS NOT NULL          -- a NULL date would vanish into no month
          AND g.AccountNumber IS NOT NULL
        GROUP BY UPPER(LTRIM(RTRIM(g.AccountNumber)))
    ),
    allocationData AS (
        SELECT
            UPPER(LTRIM(RTRIM(AccountNumber))) COLLATE Latin1_General_CI_AS AS AccountNumber,
            SUM(CONVERT(decimal(19,4), Allocation)) AS Allocation
        FROM [FinanceAutomationSystem].[dbo].[0040CBudgetsAllocation]
        WHERE FinancialYear = @FinancialYear
          AND AccountNumber IS NOT NULL
        GROUP BY UPPER(LTRIM(RTRIM(AccountNumber)))
    ),
    -- FY N runs 1 Oct (N-1) to 30 Sep N. Sargable DATE bounds replace the
    -- original's per-row CASE on YEAR(CAST(ReqDateCreated AS DATE)).
    --
    -- Encumbrance amounts ARE snapshotted, deliberately.
    --
    -- An earlier revision read them live in dbo.vw_FinanceLedger so that
    -- allocation balances were accurate intraday. That was reverted once it was
    -- established that nobody uses the current-state balance as a "right now"
    -- figure: executives read the previous CLOSED month and earlier, never the
    -- current month. Snapshotting everything keeps one consistent as-of date
    -- across GL, allocation and encumbrance, which is both simpler and less
    -- misleading than mixing live and snapshotted money in the same row.
    encumbranceData AS (
        SELECT
            UPPER(LTRIM(RTRIM(GLAccount))) COLLATE Latin1_General_CI_AS AS AccountNumber,
            SUM(CASE WHEN Status IN ('AP','PO')      THEN CONVERT(decimal(19,4), ExtendedCost) ELSE 0 END) AS Approved,
            SUM(CASE WHEN Status IN ('RT','HD','PN') THEN CONVERT(decimal(19,4), ExtendedCost) ELSE 0 END) AS Routing
        FROM [FinanceAutomationSystem].[dbo].[0040DBudgetsEncumbrance]
        WHERE Status IN ('AP','PO','RT','HD','PN')
          AND GLAccount IS NOT NULL
          AND ReqDateCreated >= DATEFROMPARTS(CONVERT(int, @FinancialYear) - 1, 10, 1)
          AND ReqDateCreated <  DATEFROMPARTS(CONVERT(int, @FinancialYear),     10, 1)
        GROUP BY UPPER(LTRIM(RTRIM(GLAccount)))
    ),
    -- Correction (a): the complete account base for the year.
    accountBase AS (
        SELECT AccountNumber FROM glData
        UNION
        SELECT AccountNumber FROM allocationData
        UNION
        SELECT AccountNumber FROM encumbranceData
    )
    SELECT
        @FinancialYear AS FinancialYear,
        b.AccountNumber,
        CONVERT(nvarchar(255), COALESCE(NULLIF(g.AccountDescription, ''), acctName.SegmentName, 'UNDEFINED')) AS AccountDescription,
        CONVERT(varchar(50),  seg.InstitutionSeg)    AS InstitutionID,
        CONVERT(varchar(50),  seg.ResponsibilitySeg) AS ResponsibilityID,
        CONVERT(varchar(50),  seg.DepartmentSeg)     AS DepartmentID,
        CONVERT(nvarchar(255), ISNULL(cl.ClusterName,       'UNDEFINED')) AS ClusterName,
        CONVERT(nvarchar(255), ISNULL(inst.SegmentName,     'UNDEFINED')) AS InstitutionName,
        CONVERT(nvarchar(255), ISNULL(resp.SegmentName,     'UNDEFINED')) AS ResponsibilityName,
        CONVERT(nvarchar(255), ISNULL(dept.SegmentName,     'UNDEFINED')) AS DepartmentName,
        vl.LineNumber,
        CONVERT(varchar(255), vl.LineDescription) AS LineDescription,
        CONVERT(varchar(255), vl.MainGroup)       AS MainGroup,
        CONVERT(varchar(255), vl.SubGroupA)       AS SubGroupA,
        CONVERT(varchar(255), vl.SubGroupB)       AS SubGroupB,
        ISNULL(g.[Oct], 0) AS [Oct], ISNULL(g.[Nov], 0) AS [Nov], ISNULL(g.[Dec], 0) AS [Dec],
        ISNULL(g.[Jan], 0) AS [Jan], ISNULL(g.[Feb], 0) AS [Feb], ISNULL(g.[Mar], 0) AS [Mar],
        ISNULL(g.[Apr], 0) AS [Apr], ISNULL(g.[May], 0) AS [May], ISNULL(g.[Jun], 0) AS [Jun],
        ISNULL(g.[Jul], 0) AS [Jul], ISNULL(g.[Aug], 0) AS [Aug], ISNULL(g.[Sep], 0) AS [Sep],
        ISNULL(g.[Oct],0) + ISNULL(g.[Nov],0) + ISNULL(g.[Dec],0) AS Q1,
        ISNULL(g.[Jan],0) + ISNULL(g.[Feb],0) + ISNULL(g.[Mar],0) AS Q2,
        ISNULL(g.[Apr],0) + ISNULL(g.[May],0) + ISNULL(g.[Jun],0) AS Q3,
        ISNULL(g.[Jul],0) + ISNULL(g.[Aug],0) + ISNULL(g.[Sep],0) AS Q4,
        ISNULL(g.[Oct],0) + ISNULL(g.[Nov],0) + ISNULL(g.[Dec],0)
          + ISNULL(g.[Jan],0) + ISNULL(g.[Feb],0) + ISNULL(g.[Mar],0)
          + ISNULL(g.[Apr],0) + ISNULL(g.[May],0) + ISNULL(g.[Jun],0)
          + ISNULL(g.[Jul],0) + ISNULL(g.[Aug],0) + ISNULL(g.[Sep],0) AS YTDTotal,
        ISNULL(e.Approved,   0) AS Approved,
        ISNULL(e.Routing,    0) AS Routing,
        ISNULL(a.Allocation, 0) AS Allocation
    FROM accountBase AS b
    -- Correction (e): layout-independent account-number splitter.
    --   {prefix}-{account}-{institution}-{responsibility}-{department}-{..}-{..}
    --   e.g. 4 - 80400 - H01 - 107 - 1157 - 00 - 000
    CROSS APPLY (SELECT NULLIF(CHARINDEX('-', b.AccountNumber), 0) AS d1) AS p1
    CROSS APPLY (SELECT NULLIF(CHARINDEX('-', b.AccountNumber, p1.d1 + 1), 0) AS d2) AS p2
    CROSS APPLY (SELECT NULLIF(CHARINDEX('-', b.AccountNumber, p2.d2 + 1), 0) AS d3) AS p3
    CROSS APPLY (SELECT NULLIF(CHARINDEX('-', b.AccountNumber, p3.d3 + 1), 0) AS d4) AS p4
    CROSS APPLY (SELECT NULLIF(CHARINDEX('-', b.AccountNumber, p4.d4 + 1), 0) AS d5) AS p5
    CROSS APPLY (
        SELECT
            LTRIM(RTRIM(SUBSTRING(b.AccountNumber, p1.d1 + 1, p2.d2 - p1.d1 - 1))) AS AccountSeg,
            LTRIM(RTRIM(SUBSTRING(b.AccountNumber, p2.d2 + 1, p3.d3 - p2.d2 - 1))) AS InstitutionSeg,
            LTRIM(RTRIM(SUBSTRING(b.AccountNumber, p3.d3 + 1, p4.d4 - p3.d3 - 1))) AS ResponsibilitySeg,
            LTRIM(RTRIM(SUBSTRING(b.AccountNumber, p4.d4 + 1, p5.d5 - p4.d4 - 1))) AS DepartmentSeg
    ) AS seg
    INNER JOIN varianceLines AS vl ON vl.AccountSeg     = seg.AccountSeg
    LEFT  JOIN glData         AS g ON g.AccountNumber   = b.AccountNumber
    LEFT  JOIN allocationData AS a ON a.AccountNumber   = b.AccountNumber
    LEFT  JOIN encumbranceData AS e ON e.AccountNumber  = b.AccountNumber
    LEFT  JOIN segName AS acctName ON acctName.SegmentNumber = '2' AND acctName.SegmentID = seg.AccountSeg
    LEFT  JOIN segName AS inst     ON inst.SegmentNumber     = '3' AND inst.SegmentID     = seg.InstitutionSeg
    LEFT  JOIN segName AS resp     ON resp.SegmentNumber     = '4' AND resp.SegmentID     = seg.ResponsibilitySeg
    LEFT  JOIN segName AS dept     ON dept.SegmentNumber     = '5' AND dept.SegmentID     = seg.DepartmentSeg
    LEFT  JOIN clusterLookup AS cl ON cl.InstitutionCode = seg.InstitutionSeg
);
GO

/* ===========================================================================
   3. Snapshot tables
   ---------------------------------------------------------------------------
   Explicit DDL, not SELECT * INTO. Two reasons, both load-bearing:
     - SELECT * INTO would bake the source float types into the snapshot
       permanently, defeating correction (d);
     - INSERT ... SELECT * binds by POSITION, so a future column reorder would
       silently load money into a description column with no error. Every
       INSERT in this file therefore carries an explicit column list.

   Grain is (FinancialYear, AccountNumber) - user-agnostic. UserName is joined
   on live in vw_FinanceLedger, so permission changes need no refresh.
   =========================================================================== */
IF OBJECT_ID('dbo.FinanceLedgerSnapshot', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.FinanceLedgerSnapshot
    (
        FinancialYear      varchar(10)   NOT NULL,
        AccountNumber      varchar(255)  COLLATE Latin1_General_CI_AS NOT NULL,
        AccountDescription nvarchar(255) NULL,
        InstitutionID      varchar(50)   COLLATE Latin1_General_CI_AS NULL,
        ResponsibilityID   varchar(50)   COLLATE Latin1_General_CI_AS NULL,
        DepartmentID       varchar(50)   COLLATE Latin1_General_CI_AS NULL,
        ClusterName        nvarchar(255) NULL,
        InstitutionName    nvarchar(255) NULL,
        ResponsibilityName nvarchar(255) NULL,
        DepartmentName     nvarchar(255) NULL,
        LineNumber         float         NULL,
        LineDescription    varchar(255)  NULL,
        MainGroup          varchar(255)  NULL,
        SubGroupA          varchar(255)  NULL,
        SubGroupB          varchar(255)  NULL,
        [Oct] decimal(19,4) NOT NULL, [Nov] decimal(19,4) NOT NULL, [Dec] decimal(19,4) NOT NULL,
        [Jan] decimal(19,4) NOT NULL, [Feb] decimal(19,4) NOT NULL, [Mar] decimal(19,4) NOT NULL,
        [Apr] decimal(19,4) NOT NULL, [May] decimal(19,4) NOT NULL, [Jun] decimal(19,4) NOT NULL,
        [Jul] decimal(19,4) NOT NULL, [Aug] decimal(19,4) NOT NULL, [Sep] decimal(19,4) NOT NULL,
        Q1 decimal(19,4) NOT NULL, Q2 decimal(19,4) NOT NULL,
        Q3 decimal(19,4) NOT NULL, Q4 decimal(19,4) NOT NULL,
        YTDTotal   decimal(19,4) NOT NULL,
        Approved   decimal(19,4) NOT NULL,
        Routing    decimal(19,4) NOT NULL,
        Allocation decimal(19,4) NOT NULL
    );

    -- Leading FinancialYear because every app query filters on it; the access
    -- join then seeks on (ResponsibilityID, DepartmentID).
    CREATE CLUSTERED INDEX CIX_FinanceLedgerSnapshot
        ON dbo.FinanceLedgerSnapshot (FinancialYear, ResponsibilityID, DepartmentID, AccountNumber);
END
GO

IF OBJECT_ID('dbo.FinanceLedgerSnapshot_Staging', 'U') IS NULL
BEGIN
    SELECT TOP (0) *
    INTO dbo.FinanceLedgerSnapshot_Staging
    FROM dbo.FinanceLedgerSnapshot;

    CREATE CLUSTERED INDEX CIX_FinanceLedgerSnapshot_Staging
        ON dbo.FinanceLedgerSnapshot_Staging (FinancialYear, ResponsibilityID, DepartmentID, AccountNumber);
END
GO

/* Freshness + outcome metadata, one row per fiscal year. The app reads
   MAX(RefreshedAt) to version its filter caches. */
IF OBJECT_ID('dbo.FinanceLedgerRefresh', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.FinanceLedgerRefresh
    (
        FinancialYear   varchar(10)   NOT NULL PRIMARY KEY,
        RefreshedAt     datetime2(0)  NOT NULL,
        RowsLoaded      int           NOT NULL,
        DurationSeconds int           NOT NULL,
        TotalAllocation decimal(19,4) NOT NULL,
        TotalYTD        decimal(19,4) NOT NULL,
        Outcome         varchar(20)   NOT NULL,   -- OK | ABORTED
        Message         nvarchar(1000) NULL
    );
END
GO

/* ===========================================================================
   4. dbo.vw_FinanceLedger - the app's read surface
   ---------------------------------------------------------------------------
   Columns are named EXPLICITLY, which is required rather than stylistic: the
   original script emits D.Cluster, but the app binds ClusterName throughout,
   and without the alias every cluster cell renders as a dash.

   The three derived money columns are computed here rather than stored, so
   the rule lives in exactly one place. AllocationBalance floors at zero and
   the overspend is reported separately as Excess - a negative balance would
   net off another account's headroom in a totals row and overstate available
   funds.

   Everything else is read straight from the snapshot, so every figure in a row
   shares ONE as-of date. An earlier revision read encumbrances live while the
   GL stayed snapshotted; that was reverted once it was established that nobody
   uses the allocation balance as a current-state figure. Mixing live and
   snapshotted money in the same row is worse than either on its own - the
   commitment moves while the spend it becomes lags behind, so balances read
   high. If current-state balances are ever needed, change the REFRESH CADENCE
   rather than making one column live.
   =========================================================================== */
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
    s.YTDTotal + s.Approved + s.Routing AS ActualExpenditure,
    CASE WHEN s.Allocation - (s.YTDTotal + s.Approved + s.Routing) < 0
         THEN ABS(s.Allocation - (s.YTDTotal + s.Approved + s.Routing))
         ELSE CONVERT(decimal(19,4), 0) END AS Excess,
    CASE WHEN s.Allocation - (s.YTDTotal + s.Approved + s.Routing) > 0
         THEN s.Allocation - (s.YTDTotal + s.Approved + s.Routing)
         ELSE CONVERT(decimal(19,4), 0) END AS AllocationBalance
FROM dbo.FinanceLedgerSnapshot AS s
INNER JOIN dbo.vw_WebAppUserAccess AS ua
    ON ua.ResponsibilityID = s.ResponsibilityID
   AND ua.DepartmentID     = s.DepartmentID;
GO

/* ===========================================================================
   5. dbo.usp_RefreshFinanceLedgerSnapshot
   ---------------------------------------------------------------------------
   Builds one fiscal year into staging, applies the sanity gates, then swaps
   that year's slice into the live table in one short transaction.

   A refresh that ERRORS is already safe - it never reaches the swap. The
   dangerous case is one that SUCCEEDS against a degraded source (a linked
   server returning nothing, a half-loaded GL) and quietly writes a truncated
   result over good data. The gates below exist for that case: they abort,
   keep the previous snapshot, record the reason, and THROW so the caller sees
   a failure rather than a silent no-op.

   @Force bypasses the movement gates for a genuine large change - a new FY
   opening, a bulk reallocation. It never bypasses the zero-row gate.
   =========================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_RefreshFinanceLedgerSnapshot
    @FinancialYear  varchar(10),
    @Force          bit = 0,
    @MinRows        int = 1,
    @MaxDropPercent decimal(5,2) = 10.00,   -- row-count fall vs last good load
    @MaxMovePercent decimal(5,2) = 25.00    -- money movement vs last good load
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @FinancialYear IS NULL OR TRY_CONVERT(int, @FinancialYear) IS NULL
        THROW 51000, 'usp_RefreshFinanceLedgerSnapshot: @FinancialYear must be a numeric year, e.g. ''2026''.', 1;

    DECLARE @startedAt datetime2(0) = SYSDATETIME();
    DECLARE @rows int, @alloc decimal(19,4), @ytd decimal(19,4);
    DECLARE @prevRows int, @prevAlloc decimal(19,4), @prevYtd decimal(19,4);
    DECLARE @abort nvarchar(1000) = NULL;

    /* ---- schema-drift guard ------------------------------------------------
       The snapshot and the function must agree on column names, or the
       explicit INSERT below starts writing the wrong values into the right
       columns. Compared by name, both directions. */
    IF EXISTS (
        SELECT name COLLATE Latin1_General_CI_AS FROM sys.dm_exec_describe_first_result_set
            (N'SELECT * FROM dbo.fn_FinanceLedgerSource(''2026'')', NULL, 0)
        EXCEPT
        SELECT name COLLATE Latin1_General_CI_AS FROM sys.columns WHERE object_id = OBJECT_ID('dbo.FinanceLedgerSnapshot')
    )
    OR EXISTS (
        SELECT name COLLATE Latin1_General_CI_AS FROM sys.columns WHERE object_id = OBJECT_ID('dbo.FinanceLedgerSnapshot')
        EXCEPT
        SELECT name COLLATE Latin1_General_CI_AS FROM sys.dm_exec_describe_first_result_set
            (N'SELECT * FROM dbo.fn_FinanceLedgerSource(''2026'')', NULL, 0)
    )
        THROW 51001, 'usp_RefreshFinanceLedgerSnapshot: column drift between fn_FinanceLedgerSource and FinanceLedgerSnapshot. Re-run sql/FinanceLedger.sql.', 1;

    /* ---- build into staging ---------------------------------------------- */
    DELETE FROM dbo.FinanceLedgerSnapshot_Staging WHERE FinancialYear = @FinancialYear;

    INSERT INTO dbo.FinanceLedgerSnapshot_Staging
    (
        FinancialYear, AccountNumber, AccountDescription,
        InstitutionID, ResponsibilityID, DepartmentID,
        ClusterName, InstitutionName, ResponsibilityName, DepartmentName,
        LineNumber, LineDescription, MainGroup, SubGroupA, SubGroupB,
        [Oct],[Nov],[Dec],[Jan],[Feb],[Mar],[Apr],[May],[Jun],[Jul],[Aug],[Sep],
        Q1, Q2, Q3, Q4, YTDTotal, Approved, Routing, Allocation
    )
    SELECT
        FinancialYear, AccountNumber, AccountDescription,
        InstitutionID, ResponsibilityID, DepartmentID,
        ClusterName, InstitutionName, ResponsibilityName, DepartmentName,
        LineNumber, LineDescription, MainGroup, SubGroupA, SubGroupB,
        [Oct],[Nov],[Dec],[Jan],[Feb],[Mar],[Apr],[May],[Jun],[Jul],[Aug],[Sep],
        Q1, Q2, Q3, Q4, YTDTotal, Approved, Routing, Allocation
    FROM dbo.fn_FinanceLedgerSource(@FinancialYear);

    SELECT
        @rows  = COUNT(*),
        @alloc = ISNULL(SUM(Allocation), 0),
        @ytd   = ISNULL(SUM(YTDTotal), 0)
    FROM dbo.FinanceLedgerSnapshot_Staging
    WHERE FinancialYear = @FinancialYear;

    SELECT @prevRows = RowsLoaded, @prevAlloc = TotalAllocation, @prevYtd = TotalYTD
    FROM dbo.FinanceLedgerRefresh
    WHERE FinancialYear = @FinancialYear AND Outcome = 'OK';

    /* ---- sanity gates ----------------------------------------------------- */
    IF @rows = 0
        SET @abort = N'Staging is empty - the source returned no rows.';
    ELSE IF @rows < @MinRows
        SET @abort = N'Staging row count ' + CONVERT(nvarchar(20), @rows)
                   + N' is below the floor of ' + CONVERT(nvarchar(20), @MinRows) + N'.';

    IF @abort IS NULL AND @Force = 0 AND @prevRows IS NOT NULL AND @prevRows > 0
    BEGIN
        IF (100.0 * (@prevRows - @rows) / @prevRows) > @MaxDropPercent
            SET @abort = N'Row count fell from ' + CONVERT(nvarchar(20), @prevRows)
                       + N' to ' + CONVERT(nvarchar(20), @rows) + N'.';
        ELSE IF @prevAlloc <> 0 AND ABS(100.0 * (@alloc - @prevAlloc) / @prevAlloc) > @MaxMovePercent
            SET @abort = N'Total allocation moved from ' + CONVERT(nvarchar(40), @prevAlloc)
                       + N' to ' + CONVERT(nvarchar(40), @alloc) + N'.';
        ELSE IF @prevYtd <> 0 AND ABS(100.0 * (@ytd - @prevYtd) / @prevYtd) > @MaxMovePercent
            SET @abort = N'Total YTD moved from ' + CONVERT(nvarchar(40), @prevYtd)
                       + N' to ' + CONVERT(nvarchar(40), @ytd) + N'.';
    END

    IF @abort IS NOT NULL
    BEGIN
        DELETE FROM dbo.FinanceLedgerSnapshot_Staging WHERE FinancialYear = @FinancialYear;

        -- Recorded as its own row state so a monitoring query can find it, but
        -- the last good load's figures are NOT overwritten.
        MERGE dbo.FinanceLedgerRefresh AS t
        USING (SELECT @FinancialYear AS FinancialYear) AS s ON t.FinancialYear = s.FinancialYear
        WHEN MATCHED THEN UPDATE SET Outcome = 'ABORTED', Message = @abort
        WHEN NOT MATCHED THEN INSERT (FinancialYear, RefreshedAt, RowsLoaded, DurationSeconds, TotalAllocation, TotalYTD, Outcome, Message)
             VALUES (@FinancialYear, SYSDATETIME(), 0, 0, 0, 0, 'ABORTED', @abort);

        DECLARE @msg nvarchar(1200) = N'Refresh aborted for FY' + @FinancialYear + N': ' + @abort
                                    + N' Previous snapshot retained. Re-run with @Force = 1 if this movement is genuine.';
        THROW 51002, @msg, 1;
    END

    /* ---- swap ------------------------------------------------------------- */
    BEGIN TRANSACTION;

        DELETE FROM dbo.FinanceLedgerSnapshot WHERE FinancialYear = @FinancialYear;

        INSERT INTO dbo.FinanceLedgerSnapshot
        (
            FinancialYear, AccountNumber, AccountDescription,
            InstitutionID, ResponsibilityID, DepartmentID,
            ClusterName, InstitutionName, ResponsibilityName, DepartmentName,
            LineNumber, LineDescription, MainGroup, SubGroupA, SubGroupB,
            [Oct],[Nov],[Dec],[Jan],[Feb],[Mar],[Apr],[May],[Jun],[Jul],[Aug],[Sep],
            Q1, Q2, Q3, Q4, YTDTotal, Approved, Routing, Allocation
        )
        SELECT
            FinancialYear, AccountNumber, AccountDescription,
            InstitutionID, ResponsibilityID, DepartmentID,
            ClusterName, InstitutionName, ResponsibilityName, DepartmentName,
            LineNumber, LineDescription, MainGroup, SubGroupA, SubGroupB,
            [Oct],[Nov],[Dec],[Jan],[Feb],[Mar],[Apr],[May],[Jun],[Jul],[Aug],[Sep],
            Q1, Q2, Q3, Q4, YTDTotal, Approved, Routing, Allocation
        FROM dbo.FinanceLedgerSnapshot_Staging
        WHERE FinancialYear = @FinancialYear;

        MERGE dbo.FinanceLedgerRefresh AS t
        USING (SELECT @FinancialYear AS FinancialYear) AS s ON t.FinancialYear = s.FinancialYear
        WHEN MATCHED THEN UPDATE SET
            RefreshedAt = SYSDATETIME(), RowsLoaded = @rows,
            DurationSeconds = DATEDIFF(second, @startedAt, SYSDATETIME()),
            TotalAllocation = @alloc, TotalYTD = @ytd, Outcome = 'OK', Message = NULL
        WHEN NOT MATCHED THEN INSERT (FinancialYear, RefreshedAt, RowsLoaded, DurationSeconds, TotalAllocation, TotalYTD, Outcome, Message)
             VALUES (@FinancialYear, SYSDATETIME(), @rows, DATEDIFF(second, @startedAt, SYSDATETIME()), @alloc, @ytd, 'OK', NULL);

    COMMIT TRANSACTION;

    DELETE FROM dbo.FinanceLedgerSnapshot_Staging WHERE FinancialYear = @FinancialYear;

    SELECT
        @FinancialYear AS FinancialYear,
        @rows          AS RowsLoaded,
        DATEDIFF(second, @startedAt, SYSDATETIME()) AS DurationSeconds,
        @alloc         AS TotalAllocation,
        @ytd           AS TotalYTD;
END
GO

/* ===========================================================================
   6. dbo.usp_RefreshFinanceLedgerSnapshotAll
   ---------------------------------------------------------------------------
   Loops the fiscal years present in the source. Year-at-a-time is what makes
   the pushdown structural rather than hopeful: every call carries a sargable
   FinancialYear = @FY inside the CTEs. It also makes incremental refresh fall
   out for free - closed years never change, so schedule the current and prior
   FY often and the full loop rarely.

   @FromYear lets the scheduler refresh only recent years.
   A failing year is logged and the loop continues, so one bad year cannot
   block the rest; the proc THROWs at the end if any year failed.
   =========================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_RefreshFinanceLedgerSnapshotAll
    @FromYear varchar(10) = NULL,
    @Force    bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @years TABLE (FinancialYear varchar(10) PRIMARY KEY);

    INSERT INTO @years (FinancialYear)
    SELECT DISTINCT FinancialYear
    FROM [FinanceAutomationSystem].[dbo].[0098AFinGLMaster]
    WHERE FinancialYear IS NOT NULL
      AND TRY_CONVERT(int, FinancialYear) IS NOT NULL
      AND (@FromYear IS NULL OR TRY_CONVERT(int, FinancialYear) >= TRY_CONVERT(int, @FromYear))
    UNION
    SELECT DISTINCT FinancialYear
    FROM [FinanceAutomationSystem].[dbo].[0040CBudgetsAllocation]
    WHERE FinancialYear IS NOT NULL
      AND TRY_CONVERT(int, FinancialYear) IS NOT NULL
      AND (@FromYear IS NULL OR TRY_CONVERT(int, FinancialYear) >= TRY_CONVERT(int, @FromYear));

    DECLARE @fy varchar(10), @failed int = 0;
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT FinancialYear FROM @years ORDER BY FinancialYear;

    OPEN c;
    FETCH NEXT FROM c INTO @fy;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            EXEC dbo.usp_RefreshFinanceLedgerSnapshot @FinancialYear = @fy, @Force = @Force;
        END TRY
        BEGIN CATCH
            SET @failed = @failed + 1;
            PRINT 'FY' + @fy + ' FAILED: ' + ERROR_MESSAGE();
        END CATCH

        FETCH NEXT FROM c INTO @fy;
    END

    CLOSE c;
    DEALLOCATE c;

    IF @failed > 0
    BEGIN
        DECLARE @m nvarchar(200) = N'usp_RefreshFinanceLedgerSnapshotAll: '
            + CONVERT(nvarchar(10), @failed) + N' fiscal year(s) failed. See dbo.FinanceLedgerRefresh.';
        THROW 51003, @m, 1;
    END
END
GO

/* ===========================================================================
   OPTIONAL INDEX - NOT RECOMMENDED. Measured; it would buy ~1 second.
   ---------------------------------------------------------------------------
   An earlier version of this comment claimed the 6,377,713-row scan of
   0098AFinGLMaster was the dominant cost of the build, and that this index was
   the fix. BOTH CLAIMS ARE WRONG. Measured on production (sqlapp\SQLEXPRESS):

     COUNT(*) with no filter ................................. 0.95s
     COUNT(*) WHERE FinancialYear = '2026' ................... 0.95s  (identical)
     Full glData aggregate for one FY (4,450 accounts) ....... 0.84s
     allocationData / encumbranceData / varianceLines ........ 0.02 / 0.03 / 0.01s
     FULL build for one fiscal year .................... 74 - 175s

   The FY filter is a scan rather than a seek, exactly as the missing index
   implies - but it does not matter, because the entire GL side is about one
   second. Roughly 72+ seconds of the build is in the account-base UNION, the
   CROSS APPLY splitter and the join chain, NOT in reading the fact tables.

   So this index would remove ~1s from a 74-175s build. It is not worth
   changing a source table this application does not own. DO NOT apply it on
   the strength of the old comment; profile the join/assembly phase instead.

     -- CREATE NONCLUSTERED INDEX IX_0098AFinGLMaster_FinancialYear
     --     ON dbo.[0098AFinGLMaster] (FinancialYear)
     --     INCLUDE (TRXDate, AccountNumber, AccountDescription, NetChange);
   =========================================================================== */
