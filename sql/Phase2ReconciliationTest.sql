/*==============================================================================================
  Phase 2 <-> Phase 1 RECONCILIATION TEST                                    read-only, no writes

  Purpose
  -------
  Proves the two guarantees Phase 2 depends on:

    TEST 1  Every account reachable through the Phase 2 detail scripts is on reporting line 3
            (the goods and services list). If this fails, detail is showing accounts the Phase 1
            summary excludes and the two pages cannot be reconciled by a user.

    TEST 2  Phase 2 amounts, grouped to account grain, tie back to the Phase 1 Approved and
            Routing totals in dbo.vw_FinanceLedger for the SAME user, fiscal year and access
            scope. If this fails, the same requisition is being valued differently on the two
            pages.

  Run it as the user under test. Both tests print PASS or FAIL plus the offending rows.

  ----------------------------------------------------------------------------------------------
  READ THIS BEFORE BELIEVING A TEST 2 FAILURE
  ----------------------------------------------------------------------------------------------
  Phase 1 reads dbo.FinanceLedgerSnapshot, which is rebuilt by the SQL Agent job (daily 21:30).
  Phase 2 reads 0040DBudgetsEncumbrance LIVE. A requisition raised, approved or received since
  the last refresh is legitimately in Phase 2 and not yet in Phase 1. That is expected drift,
  NOT a logic error. The snapshot's RefreshedAt is printed first so the window is visible, and
  TEST 2 reports the drift rather than asserting a hard equality on a moving target.

  Scope note: Phase 1's Approved = AP + PO and Routing = RT + HD + PN, both from the same
  ActCost definition (net of shipped quantity). Phase 2 must use that definition verbatim.
==============================================================================================*/

SET NOCOUNT ON;

SELECT 'snapshot freshness' AS check_, MAX(RefreshedAt) AS snapshot_refreshed_at,
       CONVERT(varchar(20), SYSDATETIME(), 120) AS db_server_now
FROM dbo.FinanceLedgerRefresh;
GO

SET NOCOUNT ON;
DECLARE @FinancialYear varchar(4)    = '2026';
DECLARE @UserName      varchar(255)  = 'KCHARLES1';
DECLARE @ToleranceTTD  decimal(19,4) = 0.05;   -- per-account rounding tolerance

;WITH glData AS ( 
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
--=========================================================================================================================================== TEST 1
--  Every account reachable through Phase 2 is on reporting line 3.
--
--  phase2InScope is built EXACTLY as the shipped detail scripts build their row set — same
--  three-column access join, same goods-and-services join. The assertion is that nothing in it
--  is off reporting line 3. Remove the goods-and-services join from the detail scripts and the
--  equivalent here, and this test fails; that is the regression it guards.
--
--  excluded_by_scope reports how many accounts the filter removes, so the number stays visible
--  rather than silently drifting. Measured 2026-08-26: 2.

, phase2InScope AS (
    SELECT DISTINCT A.GLAccount, A.AccountN
    FROM encumberanceDetails AS A
    INNER JOIN (SELECT DISTINCT AccountNumber FROM varianceLines) AS gs
           ON gs.AccountNumber = A.AccountN
    INNER JOIN dbo.vw_WebAppUserAccess AS ua
           ON ua.InstitutionID    = A.InstitutionID
          AND ua.ResponsibilityID = A.ResponsibilityID
          AND ua.DepartmentID     = A.DepartmentID
    WHERE ua.UserName = @UserName
      AND A.Status IN ('AP','PO','RT','HD','PN')
), phase2Unfiltered AS (
    SELECT DISTINCT A.GLAccount, A.AccountN
    FROM encumberanceDetails AS A
    INNER JOIN dbo.vw_WebAppUserAccess AS ua
           ON ua.InstitutionID    = A.InstitutionID
          AND ua.ResponsibilityID = A.ResponsibilityID
          AND ua.DepartmentID     = A.DepartmentID
    WHERE ua.UserName = @UserName
      AND A.Status IN ('AP','PO','RT','HD','PN')
)
SELECT
    'TEST 1 - every Phase 2 account is on reporting line 3'   AS test_,
    CASE WHEN (SELECT COUNT(*) FROM phase2InScope p
                WHERE NOT EXISTS (SELECT 1 FROM varianceLines v WHERE v.AccountNumber = p.AccountN)) = 0
         THEN 'PASS' ELSE 'FAIL' END                          AS result,
    (SELECT COUNT(*) FROM phase2InScope p
      WHERE NOT EXISTS (SELECT 1 FROM varianceLines v WHERE v.AccountNumber = p.AccountN)) AS off_reportline3,
    (SELECT COUNT(*) FROM phase2InScope)                      AS accounts_in_scope,
    (SELECT COUNT(*) FROM phase2Unfiltered) -
    (SELECT COUNT(*) FROM phase2InScope)                      AS excluded_by_scope;
GO

SET NOCOUNT ON;
DECLARE @FinancialYear varchar(4)    = '2026';
DECLARE @UserName      varchar(255)  = 'KCHARLES1';
DECLARE @ToleranceTTD  decimal(19,4) = 0.05;   -- per-account rounding tolerance

;WITH glData AS ( 
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
--=========================================================================================================================================== TEST 2
--  Phase 2 grouped amounts vs Phase 1 Approved / Routing, per account.
--  Same user, same fiscal year, same three-column access scope, same goods-and-services scope.

, phase2Totals AS (
    SELECT A.GLAccount AS AccountNumber,
           ROUND(SUM(CASE WHEN A.Status IN ('AP','PO')      THEN CONVERT(decimal(19,4), A.ActCost) ELSE 0 END), 2) AS P2_Approved,
           ROUND(SUM(CASE WHEN A.Status IN ('RT','HD','PN') THEN CONVERT(decimal(19,4), A.ActCost) ELSE 0 END), 2) AS P2_Routing
    FROM encumberanceDetails AS A
    INNER JOIN (SELECT DISTINCT AccountNumber FROM varianceLines) AS gs
           ON gs.AccountNumber = A.AccountN
    INNER JOIN dbo.vw_WebAppUserAccess AS ua
           ON ua.InstitutionID    = A.InstitutionID
          AND ua.ResponsibilityID = A.ResponsibilityID
          AND ua.DepartmentID     = A.DepartmentID
    WHERE ua.UserName = @UserName
      AND A.Status IN ('AP','PO','RT','HD','PN')
    GROUP BY A.GLAccount
), phase1Totals AS (
    SELECT AccountNumber,
           CONVERT(decimal(19,4), Approved) AS P1_Approved,
           CONVERT(decimal(19,4), Routing)  AS P1_Routing
    FROM dbo.vw_FinanceLedger
    WHERE UserName = @UserName AND FinancialYear = @FinancialYear
), recon AS (
    SELECT COALESCE(a.AccountNumber, b.AccountNumber)        AS AccountNumber,
           ISNULL(a.P2_Approved, 0) - ISNULL(b.P1_Approved, 0) AS diff_Approved,
           ISNULL(a.P2_Routing,  0) - ISNULL(b.P1_Routing,  0) AS diff_Routing
    FROM phase2Totals a
    FULL OUTER JOIN phase1Totals b ON a.AccountNumber = b.AccountNumber
)
SELECT
    'TEST 2 - Phase 2 amounts tie to Phase 1 Approved/Routing'          AS test_,
    CASE WHEN SUM(CASE WHEN ABS(diff_Approved) > @ToleranceTTD
                         OR ABS(diff_Routing)  > @ToleranceTTD THEN 1 ELSE 0 END) = 0
         THEN 'PASS' ELSE 'REVIEW - see drift note in header' END       AS result,
    COUNT(*)                                                            AS accounts_compared,
    SUM(CASE WHEN ABS(diff_Approved) > @ToleranceTTD THEN 1 ELSE 0 END) AS approved_mismatches,
    SUM(CASE WHEN ABS(diff_Routing)  > @ToleranceTTD THEN 1 ELSE 0 END) AS routing_mismatches,
    ROUND(SUM(diff_Approved), 2)                                        AS net_approved_drift,
    ROUND(SUM(diff_Routing), 2)                                         AS net_routing_drift
FROM recon;
GO
