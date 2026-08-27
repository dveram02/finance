/*==============================================================================================
  SQL Web App Workings E - Approved — CORRECTED

  Derived from : sql/source/SQL Web App Workings E - Approved.sql
  Original SHA-256           : 72ff150b9749e31f62a501f90cb1cbea2368aa3607102c622fa07eedccf5819d
  Derived on   : 2026-08-26
  Phase        : 2 — requisition-line detail
  Status       : ADOPTED 2026-08-26 as the Phase 2 basis (financesqlupdatep2.md, Decision E).
                 This file, not the sql/source/ draft, is what the Phase 2 view is derived from.
                 The draft's two-way access join is not to be shipped in any form.

  ----------------------------------------------------------------------------------------------
  WHAT WAS CORRECTED (the only behavioural change)
  ----------------------------------------------------------------------------------------------
  The inline "userAccess" CTE has been REMOVED and replaced by the live access view
  dbo.vw_WebAppUserAccess, joined on all THREE access columns.

  The original joined user access on two columns (ResponsibilityID + DepartmentID) and did not
  select InstitutionID at all, while Phase 1 (SQL Revised Allocation Oversight F, live since
  2026-08-26) joins on three. Measured on production for KCHARLES1 / FY2026, the original form:

      * matched departments in ANY institution — 47-48 institutions returned against 2 granted;
      * fanned out every row on the 32 (Responsibility, Department) pairs that span two
        institutions, because the userAccess CTE carried no DISTINCT (160 rows / 128 pairs).

      Measured for KCHARLES1 / FY2026, Status IN ('AP','PO'), production 2026-08-26.
      Three columns, because three separate corrections land here and each moves the number:

                                    rows    distinct lines   ExtendedCost (TTD)   accounts
        draft, as supplied        30,626        16,702      2,711,349,433.34        521
        + three-way access join    3,452         3,452         38,080,501.68        147
        + line-3 scope + ActCost   3,408         3,408         41,936,916.59        145   <- SHIPS

      Institutions returned: 48 in the draft, 2 after the access fix. KCHARLES1 is granted 2.

      The 30,626 vs 16,702 gap in the first row is the fan-out: 13,924 duplicated rows, value
      inflated 1.99x. Shipping the draft would report TTD 2.71bn against a correct 41.9M.

      NOTE the value RISES between rows 2 and 3 even though 6 accounts are removed. That is the
      ActCost floor: unfloored, over-shipped lines carried large NEGATIVE commitments that were
      netting off genuine ones. See ENCUMBRANCE COST below.

      The shipping figure ties EXACTLY to the Phase 1 summary: SUM(Approved) in vw_FinanceLedger
      for the same user and FY is 41,936,916.59. Account counts differ by presentation only:
      145 accounts carry AP/PO ROWS, 141 carry a NON-ZERO Approved value (the rest floor to 0).
      Verified by sql/Phase2ReconciliationTest.sql (TEST 2: 0 mismatches over 831 accounts).

  Using the view rather than an inline CTE fixes four things at once:
    1. three-way (institution-scoped) access, matching Phase 1;
    2. no fan-out — the view is DISTINCT on (UserName, InstitutionID, ResponsibilityID,
       DepartmentID); verified 160 rows = 160 distinct 4-tuples on production;
    3. no hardcoded EmployeeName — access is keyed on @UserName;
    4. the IsActive = 'TRUE' filter on BOTH control tables, which the original CTE applied to
       0006C only.

  ----------------------------------------------------------------------------------------------
  WHAT WAS **NOT** CHANGED (deliberately — so this file diffs cleanly against the original)
  ----------------------------------------------------------------------------------------------
  * Hardcoded FinancialYear = '2026' is now @FinancialYear, but the comparison is left as
    varchar so the implicit int/varchar conversion behaves exactly as the original did.
  * Segment parsing still uses the ORIGINAL fixed substring offsets
    (substring(GLAccount, 9, 3) etc.). sql/source/README.md lists fixed offsets among the
    defects sql/FinanceLedger.sql corrects, and the Oversight script instead takes
    AccountSegment3/4/5 from 0030ADGPCOA. RE-MEASURE if that derivation is adopted here.
  * ActCost / ActBalance were CHANGED — see ENCUMBRANCE COST below. This is the one place the
    file departs from "corrections confined to the access join", and it is required for the
    reconciliation test to pass.
  * The int/varchar join A.LineNbr = B.POLineID (int = varchar) is UNCHANGED. Phase 1 solves
    this by validating the values in the refresh proc so the build can fail closed; there is no
    equivalent guard in a live view, so this needs a decision before go-live.
  * glData, encumberanceData, allocationData, coaData and varianceLines are ALL unreferenced by
    the final SELECT — they were unreferenced in the original too. Kept for fidelity; SQL Server
    does not execute an unreferenced CTE.

  ----------------------------------------------------------------------------------------------
  ----------------------------------------------------------------------------------------------
  PERFORMANCE — measured 2026-08-26, and the attribution matters
  ----------------------------------------------------------------------------------------------
  Approved, KCHARLES1 / FY2026, on production. Four configurations were timed to work out what
  actually costs the time, because the first reading blamed the wrong thing:

      draft ActCost          + no scope join      0.5s     (both wrong)
      draft ActCost          + scope join        46s       (ActCost wrong)
      Phase 1 ActCost        + no scope join     48s       (scope wrong)
      Phase 1 ActCost        + scope join        47s       <- THIS FILE, both correct
      floor + decimal only, NO pre-aggregation    0.5s     (diagnostic only, INCORRECT output)

  Read that carefully. **The scope join is not the cost.** Either correction alone pushes the
  query to ~47s, and applying both adds nothing further. The last line isolates it: keeping the
  zero-floor and decimal conversion but dropping the shipment PRE-AGGREGATION returns to 0.5s.

  So the entire ~47s is  GROUP BY PONumber, CONVERT(int, POLineID)  over 0098FPOShipmentDetails.
  That aggregate is NOT optional — without it a duplicated (PONumber, POLineID) key fans the
  encumbrance line out, and Phase 1 records 65 such keys. Phase 1 pays this cost once per refresh,
  in a batch job. A live view pays it on every page load.

  ** RESOLVED 2026-08-26 — Phase 2 IS SNAPSHOT-BACKED. ** This measurement is what reversed the
  earlier "live views, not snapshots" recommendation (financesqlupdateprogress.md item 10; design
  in financesqlupdatep2.md). The aggregate is paid once per refresh, not per page load, and
  scope becomes a stored flag rather than a runtime join.

  ** THIS FILE IS THEREFORE A REFERENCE QUERY, NOT A PAGE QUERY. ** It is the definition the
  snapshot is built from. Do not put it behind a request path at 47s.

  Ruled out by measurement, so do not re-try: varianceLines is only 41 rows / 41 distinct
  accounts and builds in 87ms alone; hoisting it into a table variable changed nothing; and
  a @flag + OPTION(RECOMPILE) toggle did not restore the fast path either.

  Routing is unaffected — ~9s in every correct configuration.

  ----------------------------------------------------------------------------------------------
  ENCUMBRANCE COST — corrected to the Phase 1 definition, 2026-08-26
  ----------------------------------------------------------------------------------------------
  The draft computed  ROUND((Quantity - ISNULL(QTYShipped,0)) * UnitCost, 2)  against a direct
  join to 0098FPOShipmentDetails. That differs from Phase 1 in three ways, all of which broke
  reconciliation against the summary and were caught by sql/Phase2ReconciliationTest.sql:

    1. NOT FLOORED AT ZERO. An over-shipped line (QtyShipped > Quantity) produced a NEGATIVE
       commitment that netted off other lines' genuine commitments. Measured on production
       2026-08-26, this put account 4-75600-H01-211-0626-00-000 at TTD -5,945,460.79 in detail
       against +1,513,488.86 in the summary — one account accounting for most of a 9.93M gap.
       Phase 1 measured 4,365 over-shipped lines across all years, TTD 118,656,213.96.
    2. SHIPMENTS NOT PRE-AGGREGATED. Joining the shipment table directly lets a duplicated
       (PONumber, POLineID) key fan the encumbrance line out. Phase 1 pre-aggregates for exactly
       this reason and records 65 such duplicated keys.
    3. FLOAT ARITHMETIC. Quantity, UnitCost and QTYShipped are float. CLAUDE.md requires CONVERT
       to decimal(19,4) BEFORE aggregating; rounding afterwards preserves the error.

  CONVERT(int, POLineID) is deliberate and matches Phase 1: POLineID is varchar while LineNbr is
  int. Phase 1 relies on its refresh proc validating the values first and failing closed. A live
  view has no such pre-pass, so a non-numeric POLineID will ERROR here rather than be silently
  dropped. That is the safer failure, but it remains an open item for Phase 2 implementation.

  GOODS AND SERVICES SCOPE — DECIDED 2026-08-26, APPLIED
  ----------------------------------------------------------------------------------------------
  The Phase 1 summary INNER JOINs the reporting-line-3 account list (41 codes; payroll excluded
  by design). This script now applies the same scope, via an INNER JOIN to a DISTINCT list of
  those accounts in the final SELECT.

  Rationale: these are detail / drill-down views for the summary's Approved and Routing figures.
  An account visible in detail but excluded from the summary would make the two disagree, with
  no way for a user to reconcile them. Measured 2026-08-26, this excludes exactly 2 of 215
  accounts, both genuinely off reporting line 3:
      4-80600-H01-401-0627-00-000
      4-81500-H01-307-0601-00-000

  Enforced by `sql/Phase2ReconciliationTest.sql`, which asserts that every account reachable
  through this script is on reporting line 3, and that the grouped amounts here tie back to the
  Phase 1 Approved / Routing totals for the same user, fiscal year and access scope.
==============================================================================================*/

DECLARE @FinancialYear varchar(4)   = '2026';
DECLARE @UserName      varchar(255) = 'KCHARLES1';





WITH glData AS ( 
SELECT 
FinancialYear, AccountID, AccountNumber, AccountDescription, substring( AccountNumber, 3, 5) AS AccountN, substring( AccountNumber, 9, 3) AS InstitutionID, substring( AccountNumber, 13, 3) AS ResponsibilityID, 
substring( AccountNumber, 17, 4) AS DepartmentID, FORMAT(TRXDate, 'MMM') AS MonthN, NetChange 
FROM [FinanceAutomationSystem].[Dbo].[0098AFinGLMaster] 
WHERE FinancialYear = @FinancialYear  --====================================Needs to be filterable
), 

--=========================================================================================================================================== End of Table 1

encumberanceData AS ( 
SELECT 
FinYear, GLAccount, AccountN, InstitutionID, ResponsibilityID, DepartmentID, ROUND(ISNULL(AP, 0), 2) AS AP, ROUND(ISNULL(PO, 0), 2) AS PO, ROUND((ISNULL(AP, 0) + ISNULL(PO, 0)), 2) AS Approved, ROUND(ISNULL(RT, 0), 2) AS RT, 
ROUND(ISNULL(HD, 0), 2) AS HD, ROUND(ISNULL(PN, 0), 2) AS PN, ROUND((ISNULL(RT, 0) + ISNULL(HD, 0) + ISNULL(PN, 0)), 2) AS Routing 
FROM ( 
SELECT 
GLAccount, Status, ActCost, 
CASE 
WHEN MONTH( CAST(ReqDateCreated AS DATE) ) >= 10 then YEAR( CAST(ReqDateCreated AS DATE) ) +1 
ELSE YEAR( CAST(ReqDateCreated AS DATE) ) 
END AS FinYear, substring( GLAccount, 3, 5) AS AccountN, substring( GLAccount, 9, 3) AS InstitutionID, substring( GLAccount, 13, 3) AS ResponsibilityID, substring(GLAccount, 17, 4) As DepartmentID 
FROM ( 
SELECT 
A.*, ISNULL(S.QtyShipped, 0) AS QtyShipped, Bal.ActBalance, Cost.ActCost
--  ActCost / ActBalance match the Phase 1 definition VERBATIM (sql/FinanceLedger.sql,
--  encumbranceData): floored at zero, shipments pre-aggregated, decimal(19,4) throughout.
--  See "ENCUMBRANCE COST" in the header for what the draft did instead and why it failed to
--  reconcile. Do not simplify this back.
FROM [FinanceAutomationSystem].[dbo].[0040DBudgetsEncumbrance] AS A
LEFT JOIN (
SELECT PONumber, CONVERT(int, POLineID) AS POLineID,
       SUM(CONVERT(decimal(19,4), QTYShipped)) AS QtyShipped
FROM [FinanceAutomationSystem].[dbo].[0098FPOShipmentDetails]
GROUP BY PONumber, CONVERT(int, POLineID)
) AS S ON S.PONumber = A.PONumber AND S.POLineID = A.LineNbr
CROSS APPLY (
SELECT CASE
       WHEN CONVERT(decimal(19,4), ISNULL(A.Quantity, 0)) - ISNULL(S.QtyShipped, 0) > 0
       THEN CONVERT(decimal(19,4), ISNULL(A.Quantity, 0)) - ISNULL(S.QtyShipped, 0)
       ELSE CONVERT(decimal(19,4), 0)
       END AS ActBalance
) AS Bal
CROSS APPLY (
SELECT CONVERT(decimal(19,4), Bal.ActBalance * CONVERT(decimal(19,4), ISNULL(A.UnitCost, 0))) AS ActCost
) AS Cost
) AS A 
WHERE Status IN ('AP', 'PO', 'RT', 'HD', 'PN') AND 
CASE 
WHEN MONTH( CAST(ReqDateCreated AS DATE) ) >= 10 then YEAR( CAST(ReqDateCreated AS DATE) ) +1 
ELSE YEAR( CAST(ReqDateCreated AS DATE) ) 
END = @FinancialYear  --====================================Needs to be filterable
) AS A 
PIVOT ( 
SUM(ActCost) 
FOR Status IN (AP, PO, RT, HD, PN)
) AS PivotT 
), 

--=========================================================================================================================================== End of Table 2

encumberanceDetails AS ( 
SELECT 
RequisitionNumber, PONumber, OwnerID, Name, Status, StatusName, LineNbr, ItemID, ItemDescription, SiteID, SiteLocation, GLAccount, AccountDescription, ReqDateCreated, UofM, ActBalance, CurrencyID, UnitCost, ActCost, 
Cluster, Institution, Department, ResponsibilityCentre, VendorID, VendorName, 
CASE 
WHEN MONTH( CAST(ReqDateCreated AS DATE) ) >= 10 then YEAR( CAST(ReqDateCreated AS DATE) ) +1 
ELSE YEAR( CAST(ReqDateCreated AS DATE) ) 
END AS FinYear, substring( GLAccount, 3, 5) AS AccountN, substring( GLAccount, 9, 3) AS InstitutionID, substring( GLAccount, 13, 3) AS ResponsibilityID, substring(GLAccount, 17, 4) As DepartmentID 
FROM ( 
SELECT 
A.*, ISNULL(S.QtyShipped, 0) AS QtyShipped, Bal.ActBalance, Cost.ActCost
--  ActCost / ActBalance match the Phase 1 definition VERBATIM (sql/FinanceLedger.sql,
--  encumbranceData): floored at zero, shipments pre-aggregated, decimal(19,4) throughout.
--  See "ENCUMBRANCE COST" in the header for what the draft did instead and why it failed to
--  reconcile. Do not simplify this back.
FROM [FinanceAutomationSystem].[dbo].[0040DBudgetsEncumbrance] AS A
LEFT JOIN (
SELECT PONumber, CONVERT(int, POLineID) AS POLineID,
       SUM(CONVERT(decimal(19,4), QTYShipped)) AS QtyShipped
FROM [FinanceAutomationSystem].[dbo].[0098FPOShipmentDetails]
GROUP BY PONumber, CONVERT(int, POLineID)
) AS S ON S.PONumber = A.PONumber AND S.POLineID = A.LineNbr
CROSS APPLY (
SELECT CASE
       WHEN CONVERT(decimal(19,4), ISNULL(A.Quantity, 0)) - ISNULL(S.QtyShipped, 0) > 0
       THEN CONVERT(decimal(19,4), ISNULL(A.Quantity, 0)) - ISNULL(S.QtyShipped, 0)
       ELSE CONVERT(decimal(19,4), 0)
       END AS ActBalance
) AS Bal
CROSS APPLY (
SELECT CONVERT(decimal(19,4), Bal.ActBalance * CONVERT(decimal(19,4), ISNULL(A.UnitCost, 0))) AS ActCost
) AS Cost
) AS A 
WHERE Status IN ('AP', 'PO', 'RT', 'HD', 'PN') AND 
CASE 
WHEN MONTH( CAST(ReqDateCreated AS DATE) ) >= 10 then YEAR( CAST(ReqDateCreated AS DATE) ) +1 
ELSE YEAR( CAST(ReqDateCreated AS DATE) ) 
END = @FinancialYear  --====================================Needs to be filterable

), 

--=========================================================================================================================================== End of Table 2

allocationData AS ( 
SELECT 
FinancialYear, AccountNumber, ROUND( SUM(Allocation) , 2) AS Allocation 
FROM [FinanceAutomationSystem].[Dbo].[0040CBudgetsAllocation] 
WHERE FinancialYear = @FinancialYear  --====================================Needs to be filterable
GROUP BY FinancialYear, AccountNumber 
), 

--=========================================================================================================================================== End of Table 3

coaData AS ( 
SELECT 
A.LineID, A.AccountLineID, A.AccountSegment1, A.AccountSegment2, A.AccountSegment3, A.AccountSegment4, A.AccountSegment5, A.AccountSegment6, A.AccountSegment7, A.AccountNumber, 
B.FinalAccountDescriptionVersion AS AccountDescription, A.ResponsibilityName, A.Cluster, A.InstitutionName, A.DepartmentName 
FROM [FinanceAutomationSystem].[Dbo].[0030ADGPCOA] AS A
LEFT JOIN ( 
SELECT DISTINCT 
AccountNumber, COALESCE(EditedAccountDescription, AccountDescription) AS FinalAccountDescriptionVersion 
FROM [FinanceAutomationSystem].[Dbo].[0030AEAccountNameCorrections] 
) AS B ON A.AccountSegment2 = B.AccountNumber 
), 

--=========================================================================================================================================== End of Table 4

varianceLines AS ( 
SELECT 
A.*, B.LineNumber, B.LineDescription, B.Part1, B.Part2, B.Part3, C.AccountNumber 
FROM ( 
SELECT 
LineID, ReportName 
FROM [FinanceAutomationSystem].[Dbo].[0030AACOAReports] 
WHERE LineID = 3 
) AS A 
INNER JOIN ( 
SELECT 
LineID, ReportID, LineNumber, LineDescription, LTRIM(RTRIM(PARSENAME(REPLACE(REPLACE(LineDescription, '.', ' '), ' : ', ' . '), (LEN(LineDescription) - LEN(REPLACE(LineDescription, ':', '')) + 1) ) ) ) AS Part1, 
LTRIM(RTRIM(PARSENAME(REPLACE(REPLACE(LineDescription, '.', ' '), ' : ', ' . '), (LEN(LineDescription) - LEN(REPLACE(LineDescription, ':', ''))) ) ) ) AS Part2, 
LTRIM(RTRIM(PARSENAME(REPLACE(REPLACE(LineDescription, '.', ' '), ' : ', ' . '), (LEN(LineDescription) - LEN(REPLACE(LineDescription, ':', '')) - 1) ) ) ) AS Part3 
FROM [FinanceAutomationSystem].[Dbo].[0030ABCOAReportlines] 
WHERE LineDescription NOT LIKE '%TOTAL%' 
) AS B ON A.LineID = B.ReportID 
INNER JOIN ( 
SELECT 
* 
FROM [FinanceAutomationSystem].[Dbo].[0030ACCOAReportAccounts] 
) AS C ON B.LineNumber = C.ReportingLineID 
)

--=========================================================================================================================================== Final projection

SELECT
A.RequisitionNumber, A.PONumber, A.StatusName, A.LineNbr, A.ItemDescription, A.AccountDescription, A.ReqDateCreated, A.UofM, A.ActBalance AS Quantity, A.UnitCost, A.ActCost AS ExtendedCost,
A.Cluster, A.Institution, A.Department, A.ResponsibilityCentre, A.VendorName, A.FinYear
FROM encumberanceDetails AS A
/*  Reporting-line-3 (goods and services) scope — DECIDED 2026-08-26, see header.
    These are drill-down views for the summary's Approved / Routing figures, so they must carry
    the SAME account scope as the summary. Without it, detail lists accounts the summary excludes
    and the two disagree. Removes 2 accounts, both genuinely off reporting line 3:
    4-80600-H01-401-0627-00-000 and 4-81500-H01-307-0601-00-000.

    Written as a JOIN to a DISTINCT list, not a correlated EXISTS. Measured on production
    2026-08-26: as an EXISTS this ran in 187s; as this join, 46s. The EXISTS form re-expanded the
    varianceLines CTE per row.

    This scope join adds NO measurable cost on top of the corrected ActCost. See PERFORMANCE in
    the header for the attribution — the earlier reading that blamed this join was wrong.

    The DISTINCT is a guard, not a fix — the list cannot currently fan out — but a join to a
    non-distinct list WOULD duplicate detail rows, the same class of defect as the access-join
    fan-out this file exists to correct.
    AccountN is segment 2, the same grain the Phase 1 summary matches on.                      */
INNER JOIN (SELECT DISTINCT AccountNumber FROM varianceLines) AS gs
       ON gs.AccountNumber = A.AccountN
INNER JOIN dbo.vw_WebAppUserAccess AS ua
       ON ua.InstitutionID    = A.InstitutionID
      AND ua.ResponsibilityID = A.ResponsibilityID
      AND ua.DepartmentID     = A.DepartmentID
WHERE ua.UserName = @UserName
  AND A.Status IN ('AP', 'PO')
;
