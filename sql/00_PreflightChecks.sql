/* ============================================================================
   Finance Automation - PRODUCTION pre-flight checks
   DB: FinanceAutomationSystem

   PURPOSE
     Every figure in financeupdate.md was measured against the DEV server
     (10.5.12.3\SQLEXPRESS), which is known to be behind production. This
     script re-takes those measurements on production so the migration plan
     rests on real numbers.

   SAFETY
     100% READ-ONLY. No CREATE, ALTER, DROP, INSERT, UPDATE or DELETE.
     Nothing here writes, locks or blocks. Safe to run during business hours,
     with the exception of CHECK 12 (timing probe) - see its note.

   HOW TO RUN
     Open in SSMS against production, Results-to-Grid, Execute. Each check
     returns one labelled result set. Send the grids back, or export to Excel.

   ASCII-only by design - SSMS can misread UTF-8 without a BOM.
   ============================================================================ */

USE [FinanceAutomationSystem];
GO

SET NOCOUNT ON;
GO

PRINT '=== Finance pre-flight: server context ===';
SELECT
    'CHECK 0: server context'          AS check_name,
    @@SERVERNAME                       AS server_name,
    DB_NAME()                          AS database_name,
    SERVERPROPERTY('Edition')          AS edition,
    SERVERPROPERTY('ProductVersion')   AS product_version,
    SERVERPROPERTY('EngineEdition')    AS engine_edition,   -- 2=Standard 3=Enterprise/Developer 4=Express
    DATABASEPROPERTYEX(DB_NAME(), 'Collation') AS db_collation;
GO

/* ---------------------------------------------------------------------------
   CHECK 1  *** THE BLOCKER ***
   Which reporting-table naming scheme exists on production?
     0030AA / 0030AB / 0030AC  -> the new script is correct as written
     0030A  / 0030B  / 0030C   -> the new script needs its 3 table refs changed
   If BOTH appear, the rename is mid-flight and nothing should be cut over yet.
   -------------------------------------------------------------------------- */
SELECT
    'CHECK 1: reporting tables' AS check_name,
    o.name                      AS object_name,
    o.type_desc,
    o.create_date,
    o.modify_date
FROM sys.objects o
WHERE o.name LIKE '0030%'
ORDER BY o.name;
GO

/* ---------------------------------------------------------------------------
   CHECK 2  Do the two live views actually execute on production?
   If CHECK 1 shows the tables were renamed and these fail, production is
   currently serving "data source unavailable" on all three pages, and the
   Phase 0 hotfix is needed immediately.
   -------------------------------------------------------------------------- */
BEGIN TRY
    DECLARE @probe int;
    SELECT TOP (1) @probe = 1 FROM dbo.MonthlyExpenditure;
    SELECT 'CHECK 2a: dbo.MonthlyExpenditure' AS check_name, 'OK - executes' AS result;
END TRY
BEGIN CATCH
    SELECT 'CHECK 2a: dbo.MonthlyExpenditure' AS check_name,
           'FAILS: ' + ERROR_MESSAGE()        AS result;
END CATCH
GO

BEGIN TRY
    DECLARE @probe2 int;
    SELECT TOP (1) @probe2 = 1 FROM dbo.vw_BudgetAllocation;
    SELECT 'CHECK 2b: dbo.vw_BudgetAllocation' AS check_name, 'OK - executes' AS result;
END TRY
BEGIN CATCH
    SELECT 'CHECK 2b: dbo.vw_BudgetAllocation' AS check_name,
           'FAILS: ' + ERROR_MESSAGE()         AS result;
END CATCH
GO

/* ---------------------------------------------------------------------------
   CHECK 3  Linked server health (GL00100 was intermittently absent on dev).
   GL00100 is designed OUT of the new source, so a failure here is informational
   - but it tells us whether the same instability exists on production.
   -------------------------------------------------------------------------- */
BEGIN TRY
    DECLARE @gl00100 int;
    SELECT @gl00100 = COUNT(*) FROM [GPSWRHA.SWRHA.CO.TT].[SWRHA].[dbo].[GL00100];
    SELECT 'CHECK 3a: GL00100' AS check_name, CAST(@gl00100 AS varchar(20)) + ' rows' AS result;
END TRY
BEGIN CATCH
    SELECT 'CHECK 3a: GL00100' AS check_name, 'FAILS: ' + ERROR_MESSAGE() AS result;
END CATCH
GO

BEGIN TRY
    DECLARE @gl40200 int;
    SELECT @gl40200 = COUNT(*) FROM [GPSWRHA.SWRHA.CO.TT].[SWRHA].[dbo].[GL40200];
    SELECT 'CHECK 3b: GL40200' AS check_name, CAST(@gl40200 AS varchar(20)) + ' rows' AS result;
END TRY
BEGIN CATCH
    SELECT 'CHECK 3b: GL40200' AS check_name, 'FAILS: ' + ERROR_MESSAGE() AS result;
END CATCH
GO

/* ---------------------------------------------------------------------------
   CHECK 4  *** HIGHEST VALUE ***
   Allocation-only accounts: budgeted but with no GL activity.
   The new script drives from GL and LEFT JOINs allocation, so these vanish.
   On dev this was 1,117 accounts / TTD 21.1M in FY2026.
   -------------------------------------------------------------------------- */
SELECT
    'CHECK 4: allocation-only accounts' AS check_name,
    A.FinancialYear,
    COUNT(*)                                                           AS allocated_accounts,
    SUM(CASE WHEN G.AccountNumber IS NULL THEN 1 ELSE 0 END)           AS with_no_gl_activity,
    CAST(SUM(CASE WHEN G.AccountNumber IS NULL THEN A.Alloc ELSE 0 END)
         AS decimal(19,2))                                             AS allocation_at_risk
FROM (
    SELECT FinancialYear, AccountNumber,
           SUM(CONVERT(decimal(19,4), Allocation)) AS Alloc
    FROM dbo.[0040CBudgetsAllocation]
    GROUP BY FinancialYear, AccountNumber
) AS A
LEFT JOIN (
    SELECT DISTINCT FinancialYear, AccountNumber FROM dbo.[0098AFinGLMaster]
) AS G
    ON A.FinancialYear = G.FinancialYear
   AND A.AccountNumber = G.AccountNumber
GROUP BY A.FinancialYear
ORDER BY A.FinancialYear DESC;
GO

/* ---------------------------------------------------------------------------
   CHECK 5  Encumbrance-only accounts (same defect, Approved/Routing figures).
   -------------------------------------------------------------------------- */
SELECT
    'CHECK 5: encumbrance-only accounts' AS check_name,
    E.FinYear,
    COUNT(*)                                                 AS encumbered_accounts,
    SUM(CASE WHEN G.AccountNumber IS NULL THEN 1 ELSE 0 END) AS with_no_gl_activity
FROM (
    SELECT DISTINCT
        CASE WHEN MONTH(CAST(ReqDateCreated AS DATE)) >= 10
             THEN YEAR(CAST(ReqDateCreated AS DATE)) + 1
             ELSE YEAR(CAST(ReqDateCreated AS DATE)) END AS FinYear,
        GLAccount AS AccountNumber
    FROM dbo.[0040DBudgetsEncumbrance]
    WHERE Status IN ('AP','PO','RT','HD','PN')
) AS E
LEFT JOIN (
    SELECT DISTINCT FinancialYear, AccountNumber FROM dbo.[0098AFinGLMaster]
) AS G
    ON CAST(E.FinYear AS varchar(10)) = G.FinancialYear
   AND E.AccountNumber = G.AccountNumber
GROUP BY E.FinYear
ORDER BY E.FinYear DESC;
GO

/* ---------------------------------------------------------------------------
   CHECK 6  *** MOST LIKELY TO DIFFER FROM DEV ***
   User access scale and duplicate (Responsibility, Department) pairs.
   Dev had only 3 active rows, which (a) made the fan-out risk look latent and
   (b) made every timing probe optimistic, because the user join pruned to 3
   department pairs. Production user counts change both conclusions.
   -------------------------------------------------------------------------- */
SELECT
    'CHECK 6a: user access scale' AS check_name,
    COUNT(*)                                          AS raw_rows,
    COUNT(DISTINCT A.UserName)                        AS distinct_users,
    COUNT(DISTINCT CAST(A.UserName AS varchar(100)) + '|' +
                   CAST(B.ResponsibilityID AS varchar(50)) + '|' +
                   CAST(B.DepartmentID AS varchar(50))) AS distinct_triples
FROM [SWRHAExpenseControl].[dbo].[0006AWebAppControls] AS A
INNER JOIN [SWRHAExpenseControl].[dbo].[0006CWebAppPostControls] AS B
    ON A.PositionID = B.PositionID
WHERE A.IsActive = 'TRUE' AND B.IsActive = 'TRUE';
GO

-- Any rows here mean money figures WILL double for those users without DISTINCT.
SELECT
    'CHECK 6b: duplicate access pairs' AS check_name,
    A.UserName, B.ResponsibilityID, B.DepartmentID, COUNT(*) AS occurrences
FROM [SWRHAExpenseControl].[dbo].[0006AWebAppControls] AS A
INNER JOIN [SWRHAExpenseControl].[dbo].[0006CWebAppPostControls] AS B
    ON A.PositionID = B.PositionID
WHERE A.IsActive = 'TRUE' AND B.IsActive = 'TRUE'
GROUP BY A.UserName, B.ResponsibilityID, B.DepartmentID
HAVING COUNT(*) > 1
ORDER BY occurrences DESC;
GO

/* ---------------------------------------------------------------------------
   CHECK 7  varianceLines fan-out. Any rows = every money column doubles.
   NOTE: uses the 0030AA* names. If CHECK 1 shows 0030A*, edit these three
   table names and re-run.
   -------------------------------------------------------------------------- */
SELECT
    'CHECK 7: varianceLines fan-out' AS check_name,
    C.AccountNumber,
    COUNT(*) AS reporting_lines
FROM dbo.[0030AACOAReports] AS A
INNER JOIN dbo.[0030ABCOAReportlines]   AS B ON A.LineID = B.ReportID
INNER JOIN dbo.[0030ACCOAReportAccounts] AS C ON B.LineNumber = C.ReportingLineID
WHERE A.LineID = 3
  AND B.LineDescription NOT LIKE '%TOTAL%'
GROUP BY C.AccountNumber
HAVING COUNT(*) > 1
ORDER BY reporting_lines DESC;
GO

/* ---------------------------------------------------------------------------
   CHECK 8  PIVOT fan-out. The script's PIVOT implicitly groups by
   AccountID and AccountDescription, so an account carrying two descriptions
   in one FY yields two rows and doubles that account's totals.
   -------------------------------------------------------------------------- */
SELECT TOP (20)
    'CHECK 8: PIVOT fan-out' AS check_name,
    FinancialYear,
    AccountNumber,
    COUNT(DISTINCT AccountID)          AS distinct_account_ids,
    COUNT(DISTINCT AccountDescription) AS distinct_descriptions
FROM dbo.[0098AFinGLMaster]
GROUP BY FinancialYear, AccountNumber
HAVING COUNT(DISTINCT AccountID) > 1
    OR COUNT(DISTINCT AccountDescription) > 1
ORDER BY distinct_descriptions DESC, distinct_account_ids DESC;
GO

/* ---------------------------------------------------------------------------
   CHECK 9  Account-number layout. The script hardcodes byte offsets
   (3,5) (9,3) (13,3) (17,4), assuming every account is exactly 1-5-3-3-4.
   Any variation silently mis-parses into the WRONG DEPARTMENT.
   -------------------------------------------------------------------------- */
SELECT
    'CHECK 9: account layout' AS check_name,
    CHARINDEX('-', AccountNumber) AS first_dash_position,
    LEN(AccountNumber)            AS total_length,
    COUNT(*)                      AS row_count
FROM dbo.[0098AFinGLMaster]
GROUP BY CHARINDEX('-', AccountNumber), LEN(AccountNumber)
ORDER BY row_count DESC;
GO

/* ---------------------------------------------------------------------------
   CHECK 10  Data types and volume.
   Confirms the float money columns and the nvarchar/int FinancialYear join.
   -------------------------------------------------------------------------- */
SELECT
    'CHECK 10a: column types' AS check_name,
    o.name AS table_name, c.name AS column_name,
    TYPE_NAME(c.user_type_id) AS data_type, c.max_length, c.is_nullable
FROM sys.columns c
INNER JOIN sys.objects o ON c.object_id = o.object_id
WHERE (o.name = '0098AFinGLMaster'      AND c.name IN ('FinancialYear','AccountID','AccountNumber','TRXDate','NetChange'))
   OR (o.name = '0040CBudgetsAllocation' AND c.name IN ('FinancialYear','AccountNumber','Allocation'))
   OR (o.name = '0040DBudgetsEncumbrance' AND c.name IN ('GLAccount','ExtendedCost','ReqDateCreated','Status'))
ORDER BY o.name, c.column_id;
GO

SELECT
    'CHECK 10b: volume by FY' AS check_name,
    FinancialYear,
    COUNT(*) AS gl_rows
FROM dbo.[0098AFinGLMaster]
GROUP BY FinancialYear
ORDER BY FinancialYear DESC;
GO

SELECT 'CHECK 10c: encumbrance volume' AS check_name, COUNT(*) AS rows_total
FROM dbo.[0040DBudgetsEncumbrance];
GO

/* ---------------------------------------------------------------------------
   CHECK 11  Correctness hazards that fail silently rather than loudly.
   -------------------------------------------------------------------------- */
-- Non-numeric FinancialYear: would hard-error the nvarchar=int encumbrance join.
SELECT 'CHECK 11a: non-numeric FinancialYear' AS check_name, FinancialYear, COUNT(*) AS row_count
FROM dbo.[0098AFinGLMaster]
WHERE TRY_CONVERT(int, FinancialYear) IS NULL
GROUP BY FinancialYear;
GO

-- NULL TRXDate: silently dropped by FORMAT() + PIVOT.
SELECT 'CHECK 11b: NULL TRXDate' AS check_name, COUNT(*) AS row_count
FROM dbo.[0098AFinGLMaster] WHERE TRXDate IS NULL;
GO

-- Float accumulation: these two should agree. Any gap is float drift.
SELECT
    'CHECK 11c: float vs decimal' AS check_name,
    FinancialYear,
    SUM(NetChange)                                AS sum_as_float,
    SUM(CONVERT(decimal(19,4), NetChange))        AS sum_as_decimal
FROM dbo.[0098AFinGLMaster]
WHERE FinancialYear >= '2025'
GROUP BY FinancialYear
ORDER BY FinancialYear DESC;
GO

-- Segment names that will render as 'UNDEFINED' (marked REMOVE or unmapped).
SELECT
    'CHECK 11d: segment controls' AS check_name,
    SegmentNumber,
    COUNT(*) AS control_rows,
    SUM(CASE WHEN UPPER(LTRIM(RTRIM(RevisedDescription))) = 'REMOVE' THEN 1 ELSE 0 END) AS marked_remove
FROM dbo.[0000CSegmentControls]
GROUP BY SegmentNumber
ORDER BY SegmentNumber;
GO

/* ---------------------------------------------------------------------------
   CHECK 12  TIMING PROBE - RUN OFF-PEAK.
   This is the only check with real cost. It runs the current script's shape
   for ONE fiscal year across ALL users, which is closer to the snapshot build
   than the single-user form.

   Paste the body of "SQL Revised Web App.sql" below, with these two edits:
     1. remove   AND UserName = 'FFIGUERA1'   from the userControls CTE
     2. remove   the trailing ORDER BY
   then read the elapsed time from the messages pane.

   On dev this was 4.1s for one FY (but dev has only 3 active user rows, so
   expect production to be materially slower - CHECK 6a tells you by how much).

   DECLARE @t datetime2 = SYSDATETIME();
   ... paste script here ...
   SELECT DATEDIFF(millisecond, @t, SYSDATETIME()) AS elapsed_ms;
   -------------------------------------------------------------------------- */

PRINT '=== Pre-flight complete. CHECK 1, 2, 4 and 6 are the decision-makers. ===';
GO

/* ===========================================================================
   CHECKS 12-20  Added 2026-08-25 for the Allocation Oversight rollout.
   ---------------------------------------------------------------------------
   Run ALL of these against the target instance immediately before deploying.
   A restored backup is never authoritative for a live release: the
   InstitutionID column in CHECK 18 appeared between two backups taken three
   weeks apart, and the plan was rewritten twice as a result.

   Baselines below were measured on the 2026-08-25 production backup. They are
   OBSERVATIONS, not invariants - re-measure, never quote.
   =========================================================================== */

/* CHECK 12  COA grain. BLOCKING - a duplicate account number multiplies every
             money column through the coaData join.
             Baseline: 9,463 rows / 9,463 distinct / 0 duplicates. */
SELECT
    'CHECK 12: COA grain' AS check_name,
    COUNT(*)                                             AS rows_total,
    COUNT(DISTINCT UPPER(LTRIM(RTRIM(AccountNumber))))   AS distinct_accounts,
    (SELECT COUNT(*) FROM (
        SELECT 1 AS x FROM dbo.[0030ADGPCOA]
        GROUP BY UPPER(LTRIM(RTRIM(AccountNumber))) HAVING COUNT(*) > 1) AS d) AS duplicates
FROM dbo.[0030ADGPCOA];
GO

/* CHECK 13  Correction grain. BLOCKING - SELECT DISTINCT does NOT collapse an
             account whose rows disagree on the description.
             Baseline: 190 rows / 168 accounts / 0 conflicts. Duplicates exist
             but every duplicate set agrees, so the collapse is lossless. */
SELECT
    'CHECK 13: correction grain' AS check_name,
    COUNT(*)                        AS rows_total,
    COUNT(DISTINCT AccountNumber)   AS distinct_accounts,
    (SELECT COUNT(*) FROM (
        SELECT 1 AS x FROM dbo.[0030AEAccountNameCorrections]
        GROUP BY UPPER(LTRIM(RTRIM(AccountNumber)))
        HAVING COUNT(DISTINCT UPPER(COALESCE(
            NULLIF(LTRIM(RTRIM(EditedAccountDescription)), ''),
            NULLIF(LTRIM(RTRIM(AccountDescription)), '')))) > 1) AS d) AS conflicts
FROM dbo.[0030AEAccountNameCorrections];
GO

/* CHECK 14  Label coverage. The entire linked-server removal rests on these
             four columns existing and being populated. If they were all NULL
             the money would stay perfect while every page filled with
             UNDEFINED - which no money gate can detect. That is why gate 4b
             exists in the refresh proc.
             Baseline: 0 blank in all five; 24 DepartmentName and 1
             ResponsibilityName carry REMOVE/UNDEFINED sentinels. */
SELECT
    'CHECK 14: COA label coverage' AS check_name,
    COUNT(*) AS rows_total,
    SUM(CASE WHEN NULLIF(LTRIM(RTRIM(Cluster)), '')            IS NULL THEN 1 ELSE 0 END) AS blank_cluster,
    SUM(CASE WHEN NULLIF(LTRIM(RTRIM(InstitutionName)), '')    IS NULL THEN 1 ELSE 0 END) AS blank_institution,
    SUM(CASE WHEN NULLIF(LTRIM(RTRIM(ResponsibilityName)), '') IS NULL THEN 1 ELSE 0 END) AS blank_responsibility,
    SUM(CASE WHEN NULLIF(LTRIM(RTRIM(DepartmentName)), '')     IS NULL THEN 1 ELSE 0 END) AS blank_department,
    SUM(CASE WHEN NULLIF(LTRIM(RTRIM(AccountDescription)), '') IS NULL THEN 1 ELSE 0 END) AS blank_description,
    SUM(CASE WHEN UPPER(LTRIM(RTRIM(DepartmentName))) IN ('REMOVE','UNDEFINED') THEN 1 ELSE 0 END) AS sentinel_department
FROM dbo.[0030ADGPCOA];
GO

/* CHECK 15  Segment-name ambiguity. coaData matches on the FULL account
             number, with a segment-level fallback behind it for accounts
             absent from the mirror entirely (2 of 2,236 in FY2026). That
             fallback is only safe while each segment maps to exactly one name.
             Baseline: 0 / 0 / 0. */
SELECT 'CHECK 15: segment ambiguity' AS check_name,
    (SELECT COUNT(*) FROM (SELECT AccountSegment5 FROM dbo.[0030ADGPCOA]
        WHERE NULLIF(LTRIM(RTRIM(DepartmentName)), '') IS NOT NULL
        GROUP BY AccountSegment5 HAVING COUNT(DISTINCT DepartmentName) > 1) AS d) AS ambiguous_department,
    (SELECT COUNT(*) FROM (SELECT AccountSegment4 FROM dbo.[0030ADGPCOA]
        WHERE NULLIF(LTRIM(RTRIM(ResponsibilityName)), '') IS NOT NULL
        GROUP BY AccountSegment4 HAVING COUNT(DISTINCT ResponsibilityName) > 1) AS d) AS ambiguous_responsibility,
    (SELECT COUNT(*) FROM (SELECT AccountSegment3 FROM dbo.[0030ADGPCOA]
        WHERE NULLIF(LTRIM(RTRIM(InstitutionName)), '') IS NOT NULL
        GROUP BY AccountSegment3 HAVING COUNT(DISTINCT InstitutionName) > 1) AS d) AS ambiguous_institution;
GO

/* CHECK 16  Shipment conversion. BLOCKING - QTYShipped and POLineID are
             varchar while LineNbr is int. Gate 4d aborts the refresh on any
             non-convertible value rather than discarding it: a discarded
             shipment understates receipts and therefore OVERSTATES the
             commitment held against a budget.
             Baseline: 0 / 0 of 250,897. */
SELECT
    'CHECK 16: shipment conversion' AS check_name,
    COUNT(*) AS rows_total,
    SUM(CASE WHEN TRY_CONVERT(int, POLineID) IS NULL THEN 1 ELSE 0 END)             AS bad_polineid,
    SUM(CASE WHEN TRY_CONVERT(decimal(19,4), QTYShipped) IS NULL THEN 1 ELSE 0 END) AS bad_qtyshipped
FROM dbo.[0098FPOShipmentDetails];
GO

/* CHECK 17  Shipment key ambiguity. A duplicated (PONumber, POLineID) is two
             DISTINCT GP lines colliding on an insufficient key - POLNENUM
             tells them apart - so summing across them would corrupt the
             commitment.
             Baseline: 65 duplicated keys, 0 intersecting an open requisition.
             That second figure is why pre-aggregation is currently harmless.
             intersecting_open_encumbrance MUST be 0; gate 4d enforces it. */
SELECT 'CHECK 17: shipment key ambiguity' AS check_name,
    (SELECT COUNT(*) FROM (SELECT PONumber, TRY_CONVERT(int, POLineID) AS pl
        FROM dbo.[0098FPOShipmentDetails]
        GROUP BY PONumber, TRY_CONVERT(int, POLineID) HAVING COUNT(*) > 1) AS d) AS duplicated_keys,
    (SELECT COUNT(*) FROM (SELECT PONumber, TRY_CONVERT(int, POLineID) AS pl
        FROM dbo.[0098FPOShipmentDetails]
        GROUP BY PONumber, TRY_CONVERT(int, POLineID) HAVING COUNT(*) > 1) AS d
      INNER JOIN dbo.[0040DBudgetsEncumbrance] AS e
              ON e.PONumber = d.PONumber AND e.LineNbr = d.pl
      WHERE e.Status IN ('AP','PO','RT','HD','PN')) AS intersecting_open_encumbrance;
GO

/* CHECK 18  *** THE CRITICAL ONE *** InstitutionID must exist AND be populated
             on every active mapping. A blank value passes IS NOT NULL, then
             matches no account row, and the user sees an empty application
             with nothing anywhere to explain it.
             There is NO fallback to the two-way join: that rule is known to
             expose other institutions' money (measured at TTD 99.1M), so an
             absent column FAILS THE RELEASE.
             Baseline: 160 active rows, 0 blank, institutions H01 and H03. */
IF COL_LENGTH('SWRHAExpenseControl.dbo.0006CWebAppPostControls', 'InstitutionID') IS NULL
    SELECT 'CHECK 18: InstitutionID' AS check_name, 'ABSENT - RELEASE MUST NOT PROCEED' AS verdict;
ELSE
    EXEC(N'
    SELECT ''CHECK 18: InstitutionID'' AS check_name,
        COUNT(*) AS active_rows,
        SUM(CASE WHEN NULLIF(LTRIM(RTRIM(InstitutionID)), '''') IS NULL THEN 1 ELSE 0 END) AS blank_institution,
        COUNT(DISTINCT InstitutionID) AS distinct_institutions
    FROM [SWRHAExpenseControl].[dbo].[0006CWebAppPostControls] WHERE IsActive = ''TRUE'';');
GO

/* CHECK 19  Access fan-out risk. Pairs spanning more than one institution are
             exactly why vw_WebAppUserAccess must DISTINCT on the full 4-tuple
             and why both views must cut over in ONE transaction.
             Baseline: 128 distinct pairs, 32 spanning - 25% of them. */
SELECT 'CHECK 19: cross-institution pairs' AS check_name,
    (SELECT COUNT(DISTINCT CONCAT(ResponsibilityID, '|', DepartmentID))
       FROM [SWRHAExpenseControl].[dbo].[0006CWebAppPostControls] WHERE IsActive = 'TRUE') AS distinct_pairs,
    (SELECT COUNT(*) FROM (SELECT ResponsibilityID, DepartmentID
        FROM [SWRHAExpenseControl].[dbo].[0006CWebAppPostControls] WHERE IsActive = 'TRUE'
        GROUP BY ResponsibilityID, DepartmentID HAVING COUNT(DISTINCT InstitutionID) > 1) AS d) AS pairs_spanning_institutions;
GO

/* CHECK 20 (P9)  Unmatched access grants - mappings resolving to no ledger row
             at all. NOT blocking: an unused grant is an administration state,
             not a failure, and a department may legitimately have no
             goods-and-services activity. Record the number, so a POST-cutover
             increase can be told apart from a pre-existing condition. */
SELECT
    'CHECK 20: unmatched access grants' AS check_name,
    COUNT(*) AS grants_with_no_ledger_rows
FROM (
    SELECT DISTINCT
        UPPER(LTRIM(RTRIM(P.InstitutionID)))    COLLATE Latin1_General_CI_AS AS I,
        UPPER(LTRIM(RTRIM(P.ResponsibilityID))) COLLATE Latin1_General_CI_AS AS R,
        UPPER(LTRIM(RTRIM(P.DepartmentID)))     COLLATE Latin1_General_CI_AS AS D
    FROM [SWRHAExpenseControl].[dbo].[0006AWebAppControls] AS U
    INNER JOIN [SWRHAExpenseControl].[dbo].[0006CWebAppPostControls] AS P ON U.PositionID = P.PositionID
    WHERE U.IsActive = 'TRUE' AND P.IsActive = 'TRUE'
) AS g
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.FinanceLedgerSnapshot AS s
    WHERE s.InstitutionID = g.I AND s.ResponsibilityID = g.R AND s.DepartmentID = g.D
);
GO
