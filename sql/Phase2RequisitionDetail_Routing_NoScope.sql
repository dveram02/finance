/*==============================================================================================
  SQL Web App Workings E - Routing — CORRECTED, WITHOUT goods-and-services scope

  Derived from : sql/source/SQL Web App Workings E - Routing.sql
  Original SHA-256           : 3e93c4937e0087ed31e4143acb7abbf0fddc332438cb90f52754022611802989
                               (the finance team's supplied artifact, as recorded in
                               sql/source/README.md. The working copy had been whitespace/EOL
                               edited when this file was first derived; the source was restored
                               to the reference bytes on 2026-08-26 and this header now records
                               the reference hash. Functional corrections live ONLY in this file.)
  Derived on   : 2026-08-26
  Phase        : 2 — requisition-line detail
  Status       : ALTERNATIVE VARIANT — not the adopted basis. The adopted file is
                 sql/Phase2RequisitionDetail_Routing.sql (financesqlupdatep2.md, Decision E).
                 Kept so the unscoped behaviour stays runnable and comparable.
                 Read sql/Phase2ScopeVariants.md before choosing this one.
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

      Measured for KCHARLES1 / FY2026, Status IN ('RT','HD','PN'), production 2026-08-26.
      Three columns, because three separate corrections land here and each moves the number:

                                    rows    distinct lines   ExtendedCost (TTD)   accounts
        draft, as supplied         5,949         3,282        131,164,220.53        350
        + three-way access join      777           777          4,696,550.19        121
        + line-3 scope + ActCost     773           773          4,512,250.19        120   <- SHIPS

      Institutions returned: 47 in the draft, 2 after the access fix. KCHARLES1 is granted 2.

      The 5,949 vs 3,282 gap in the first row is the fan-out: 2,667 duplicated rows, value
      inflated 1.95x. The rest of the drop to row 2 is institution scoping. Row 3 applies the
      goods-and-services scope and the Phase 1 ActCost definition.

      The shipping figure ties EXACTLY to the Phase 1 summary: SUM(Routing) in vw_FinanceLedger
      for the same user and FY is 4,512,250.19 over 120 accounts.
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

GOODS AND SERVICES SCOPE — DELIBERATELY NOT APPLIED IN THIS FILE
  ----------------------------------------------------------------------------------------------
  The Phase 1 summary INNER JOINs the reporting-line-3 account list (41 codes; payroll excluded
  by design). This variant does NOT. That is the ONLY difference between it and the adopted file:
  the three-way access join, the Phase 1 ActCost definition and the parameterised fiscal year are
  all identical.

  Measured on production 2026-08-26, KCHARLES1 / FY2026:

      this variant      777 rows over 121 accounts,  ExtendedCost TTD 4,696,550.19
      adopted file      773 rows,                  ExtendedCost TTD 4,512,250.19
      difference          4 rows over 1 account(s), TTD 184,300.00

  ** CONSEQUENCE OF CHOOSING THIS FILE. ** It CANNOT reconcile to the Phase 1 summary. The extra
  accounts have no row in vw_FinanceLedger at all, so a user drilling from a summary figure into
  this detail sees a total larger by TTD 184,300.00, with nothing on either page explaining the
  gap. sql/Phase2ReconciliationTest.sql reports exactly that against this variant: TEST 1 FAILS
  with off_reportline3 = 1, and TEST 2 reports the matching mismatch. That is the EXPECTED
  result here, not a defect in the file — it IS the trade-off.

  ** THIS VARIANT IS NOT FASTER. ** It was created on the assumption that the scope join was what
  made the adopted file slow. Measured on production 2026-08-26, that assumption was WRONG:

      this variant (no scope)   ~9s
      adopted file (scoped)     ~9s

  The cost is the shipment pre-aggregation in the corrected ActCost, not the scope join — see
  PERFORMANCE in the adopted file for the four-configuration breakdown. Dropping the scope buys
  nothing.

  So choose this file ONLY if you actually want the UNSCOPED DATA — every account with
  requisition activity, including those the summary excludes. If you were reaching for it to make
  the page faster, it will not, and you give up reconciliation for no gain.

  ** SUPERSEDED BY THE PHASE 2 SNAPSHOT DESIGN (decided 2026-08-26). ** In that design the scope
  is a stored IsGoodsAndServices flag on dbo.FinanceRequisitionSnapshot, so scoped and unscoped
  become two read views over one table and both are free. This file then stops being an
  operational choice and becomes the DEFINITION of the unscoped view. See financesqlupdatep2.md
  and sql/Phase2ScopeVariants.md.

  ** DUPLICATION WARNING. ** This file shares its CTE chain, access join and ActCost definition
  with the adopted file. A correction to any of those MUST be applied to both or they silently
  diverge. Nothing enforces that.
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
END = @FinancialYear --====================================Needs to be filterable
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
END = @FinancialYear --====================================Needs to be filterable

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
INNER JOIN dbo.vw_WebAppUserAccess AS ua
       ON ua.InstitutionID    = A.InstitutionID
      AND ua.ResponsibilityID = A.ResponsibilityID
      AND ua.DepartmentID     = A.DepartmentID
WHERE ua.UserName = @UserName
  AND A.Status IN ('RT', 'HD', 'PN')
;
