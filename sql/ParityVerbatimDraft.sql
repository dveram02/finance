/* ===========================================================================
   ParityVerbatimDraft.sql
   ---------------------------------------------------------------------------
   The finance department's Access query, wrapped UNCHANGED in two inline TVFs
   so it can be executed repeatedly and diffed against the portal.

   SOURCE (immutable): sql/source/SQL Revised Allocation Oversight F.sql
   SHA-256           : 9f9f615854ed1ac5394b4b0da519e09d1df0cb8d665dc4d481ac8e5caef1d3ba

   These functions exist ONLY to prove parity. Nothing in the request path may
   ever read them - they scan 0098AFinGLMaster and 0040DBudgetsEncumbrance with
   the draft's own non-sargable predicates. They are created and dropped by the
   parity runbook (financeupdatesep.md, Part E step 9).

   THE ONLY EDITS TO THE SOURCE BODY - five literal substitutions, applied
   mechanically by sed at the line numbers shown, never by hand:

     line  10  WHERE FinancialYear = '2026'        -> @FinancialYear   (glData)
     line  40  END = '2026'                        -> @FinancialYear   (encumberanceData)
     line  72  END = '2026'                        -> @FinancialYear   (encumberanceDetails)
     line  82  WHERE FinancialYear = '2026'        -> @FinancialYear   (allocationData)
     line 143  C.EmployeeName = 'FRANCIS FIGUERA'  -> @EmployeeName    (userAccess)

   The source carries no trailing ORDER BY, so correction (h) has nothing to
   remove here.

   dbo.fn_OversightDraftUnscoped additionally DELETES two ranges so that the
   whole chart of accounts is returned rather than one employee's departments:
     lines 128-144  the userAccess CTE           (and the trailing comma on 124)
     lines 227-231  INNER JOIN ... AS D ON <3-way access predicate>
   Nothing else differs between the two functions.

   NOTE ON @FinancialYear's TYPE. The draft compares an int expression to a
   string literal at lines 40 and 72 (END = '2026'), so int datatype precedence
   converts the literal. Declaring @FinancialYear as varchar(10) preserves that
   behaviour exactly - the implicit convert still happens, in the same direction.
   =========================================================================== */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER FUNCTION dbo.fn_OversightDraftVerbatim
(
    @FinancialYear varchar(10),
    @EmployeeName  varchar(200)
)
RETURNS TABLE
AS
RETURN
(




WITH glData AS ( 
SELECT 
FinancialYear, AccountID, AccountNumber, AccountDescription, substring( AccountNumber, 3, 5) AS AccountN, substring( AccountNumber, 9, 3) AS InstitutionID, substring( AccountNumber, 13, 3) AS ResponsibilityID, 
substring( AccountNumber, 17, 4) AS DepartmentID, FORMAT(TRXDate, 'MMM') AS MonthN, NetChange 
FROM [FinanceAutomationSystem].[Dbo].[0098AFinGLMaster] 
WHERE FinancialYear = @FinancialYear 
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
A.*, ISNULL(B.QTYShipped, 0) AS QtyShipped, (Quantity - ISNULL(B.QTYShipped, 0)) AS ActBalance, ROUND(((Quantity - ISNULL(B.QTYShipped, 0)) * UnitCost),2) AS ActCost 
FROM [FinanceAutomationSystem].[dbo].[0040DBudgetsEncumbrance] AS A 
LEFT JOIN ( 
SELECT 
* 
FROM [FinanceAutomationSystem].[dbo].[0098FPOShipmentDetails] 
) AS B ON A.LineNbr = B.POLineID AND A.PONumber = B.PONumber 
) AS A 
WHERE Status IN ('AP', 'PO', 'RT', 'HD', 'PN') AND 
CASE 
WHEN MONTH( CAST(ReqDateCreated AS DATE) ) >= 10 then YEAR( CAST(ReqDateCreated AS DATE) ) +1 
ELSE YEAR( CAST(ReqDateCreated AS DATE) ) 
END = @FinancialYear 
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
A.*, ISNULL(B.QTYShipped, 0) AS QtyShipped, (Quantity - ISNULL(B.QTYShipped, 0)) AS ActBalance, ROUND(((Quantity - ISNULL(B.QTYShipped, 0)) * UnitCost),2) AS ActCost 
FROM [FinanceAutomationSystem].[dbo].[0040DBudgetsEncumbrance] AS A 
LEFT JOIN ( 
SELECT 
* 
FROM [FinanceAutomationSystem].[dbo].[0098FPOShipmentDetails] 
) AS B ON A.LineNbr = B.POLineID AND A.PONumber = B.PONumber 
) AS A 
WHERE Status IN ('AP', 'PO', 'RT', 'HD', 'PN') AND 
CASE 
WHEN MONTH( CAST(ReqDateCreated AS DATE) ) >= 10 then YEAR( CAST(ReqDateCreated AS DATE) ) +1 
ELSE YEAR( CAST(ReqDateCreated AS DATE) ) 
END = @FinancialYear 

), 

--=========================================================================================================================================== End of Table 3

allocationData AS ( 
SELECT 
FinancialYear, AccountNumber, ROUND( SUM(Allocation) , 2) AS Allocation 
FROM [FinanceAutomationSystem].[Dbo].[0040CBudgetsAllocation] 
WHERE FinancialYear = @FinancialYear 
GROUP BY FinancialYear, AccountNumber 
), 

--=========================================================================================================================================== End of Table 4

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

--=========================================================================================================================================== End of Table 5

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
), 

--=========================================================================================================================================== End of Table 6

userAccess AS ( 
SELECT 
A.EmployeeID, C.EmployeeName, A.UserName, A.PositionID, A.IsActive, B.DepartmentID, B.ResponsibilityID, B.InstitutionID
FROM [SWRHAExpenseControl].[dbo].[0006AWebAppControls] AS A
LEFT JOIN (
SELECT 
*
FROM [SWRHAExpenseControl].[dbo].[0006CWebAppPostControls]
WHERE IsActive = 'TRUE'
) AS B ON A.PositionID = B.PositionID
LEFT JOIN (
SELECT
*
FROM [ArrearsDatabase].[dbo].[0002AEmployees]
) AS C ON A.EmployeeID COLLATE Latin1_General_CI_AS = C.EmployeeID
WHERE B.DepartmentID IS NOT NULL AND C.EmployeeName = @EmployeeName  --====================================Needs to be filterable
) 

--=========================================================================================================================================== End of Table 7


SELECT
FinancialYear, AccountID, PivotT.AccountNumber, PivotT.AccountDescription, AccountN, PivotT.InstitutionID, PivotT.ResponsibilityID, PivotT.DepartmentID,
ROUND(ISNULL(Oct, 0),2) AS Oct, ROUND(ISNULL(Nov, 0),2) AS Nov, ROUND(ISNULL(Dec, 0),2) AS Dec, 
ROUND((ISNULL(Oct, 0) + ISNULL(Nov, 0) + ISNULL(Dec, 0)),2) AS Q1, 
ROUND(ISNULL(Jan, 0),2) AS Jan, ROUND(ISNULL(Feb, 0),2) AS Feb, ROUND(ISNULL(Mar, 0),2) AS Mar, 
ROUND((ISNULL(Jan, 0) + ISNULL(Feb, 0) + ISNULL(Mar, 0)),2) AS Q2,
ROUND(ISNULL(Apr, 0),2) AS Apr, ROUND(ISNULL(May, 0),2) AS May, ROUND(ISNULL(Jun, 0),2) AS Jun, 
ROUND((ISNULL(Apr, 0) + ISNULL(May, 0) + ISNULL(Jun, 0)),2) AS Q3,
ROUND(ISNULL(Jul, 0),2) AS Jul, ROUND(ISNULL(Aug, 0),2) AS Aug, ROUND(ISNULL(Sep, 0),2) AS Sep, 
ROUND((ISNULL(Jul, 0) + ISNULL(Aug, 0) + ISNULL(Sep, 0)),2) AS Q4,
ROUND((ISNULL(Oct, 0) + ISNULL(Nov, 0) + ISNULL(Dec, 0) + ISNULL(Jan, 0) + ISNULL(Feb, 0) + ISNULL(Mar, 0) + ISNULL(Apr, 0) + ISNULL(May, 0) + ISNULL(Jun, 0) + ISNULL(Jul, 0) + ISNULL(Aug, 0) + ISNULL(Sep, 0) ),2) AS YTDTotal, 
ROUND((ISNULL(Oct, 0) + ISNULL(Nov, 0) + ISNULL(Dec, 0) + ISNULL(Jan, 0) + ISNULL(Feb, 0) + ISNULL(Mar, 0) + ISNULL(Apr, 0) + ISNULL(May, 0) + ISNULL(Jun, 0) + ISNULL(Jul, 0) + ISNULL(Aug, 0) + ISNULL(Sep, 0) + ISNULL(Approved,0) ),2) AS AcutalYTDExpense, 
ROUND(ISNULL(Allocation, 0),2) AS Allocation, ROUND(ISNULL(Approved,0),2) AS Approved, ROUND(ISNULL(Routing, 0),2) AS Routing, 
CASE 
WHEN ROUND(ISNULL(Allocation,0) - (ROUND((ISNULL(Oct, 0) + ISNULL(Nov, 0) + ISNULL(Dec, 0) + ISNULL(Jan, 0) + ISNULL(Feb, 0) + ISNULL(Mar, 0) + ISNULL(Apr, 0) + ISNULL(May, 0) + ISNULL(Jun, 0) + ISNULL(Jul, 0) + 
ISNULL(Aug, 0) + ISNULL(Sep, 0) ),2)), 2) < 0 then ABS(ROUND(ISNULL(Allocation,0) - (ROUND((ISNULL(Oct, 0) + ISNULL(Nov, 0) + ISNULL(Dec, 0) + ISNULL(Jan, 0) + ISNULL(Feb, 0) + ISNULL(Mar, 0) + ISNULL(Apr, 0) + ISNULL(May, 0) + 
ISNULL(Jun, 0) + ISNULL(Jul, 0) + ISNULL(Aug, 0) + ISNULL(Sep, 0) ),2)), 2)) 
ELSE 0 
END AS ExcessTotals, 
CASE 
WHEN ROUND(ISNULL(Allocation,0) - (ROUND((ISNULL(Oct, 0) + ISNULL(Nov, 0) + ISNULL(Dec, 0) + ISNULL(Jan, 0) + ISNULL(Feb, 0) + ISNULL(Mar, 0) + ISNULL(Apr, 0) + ISNULL(May, 0) + ISNULL(Jun, 0) + ISNULL(Jul, 0) + 
ISNULL(Aug, 0) + ISNULL(Sep, 0) ),2)), 2) > 0 then ROUND(ISNULL(Allocation,0) - (ROUND((ISNULL(Oct, 0) + ISNULL(Nov, 0) + ISNULL(Dec, 0) + ISNULL(Jan, 0) + ISNULL(Feb, 0) + ISNULL(Mar, 0) + ISNULL(Apr, 0) + ISNULL(May, 0) + 
ISNULL(Jun, 0) + ISNULL(Jul, 0) + ISNULL(Aug, 0) + ISNULL(Sep, 0) ),2)), 2) 
ELSE 0 
END AS TrueBalanceOfAllocation, B.ResponsibilityName, B.Cluster AS ClusterName, B.InstitutionName, B.DepartmentName 
FROM (
SELECT
*
FROM glData
WHERE NetChange <> 0

UNION ALL

SELECT
A.FinancialYear, B.AccountLineID AS AccountID, A.AccountNumber, B.AccountDescription, B.AccountSegment2 AS AccountN, B.AccountSegment3 AS InstitutionID, B.AccountSegment4 AS ResponsibilityID,
B.AccountSegment5 AS DepartmentID, 'Allocation' AS MonthN, Allocation AS NetChange
FROM allocationData AS A
LEFT JOIN (
SELECT 
*
FROM coaData
) AS B ON A.AccountNumber = B.AccountNumber
WHERE Allocation <> 0

UNION ALL

SELECT
A.FinYear AS FinancialYear, B.AccountLineID AS AccountID, A.GLAccount AS AccountNumber, B.AccountDescription, A.AccountN, A.InstitutionID, A.ResponsibilityID, A.DepartmentID, 
Details AS MonthN, Amount AS NetChange
FROM (
SELECT
FinYear, GLAccount, AccountN, InstitutionID, ResponsibilityID, DepartmentID, Details, Amount
FROM encumberanceData
UNPIVOT (
	Amount FOR Details IN (Approved, Routing)
) AS Unpivotted
) AS A
LEFT JOIN (
SELECT 
*
FROM coaData
) AS B ON A.GLAccount = B.AccountNumber
WHERE Amount <> 0
) AS AllConsolidated
PIVOT ( 
	SUM(NetChange) 
	FOR MonthN IN (Oct, Nov, Dec, Jan, Feb, Mar, Apr, May, Jun, Jul, Aug, Sep, Allocation, Approved, Routing)
) AS PivotT 
LEFT JOIN (
SELECT 
*
FROM coaData
) AS B ON PivotT.AccountNumber = B.AccountNumber
INNER JOIN (
SELECT
*
FROM varianceLines
) AS C ON PivotT.AccountN = C.AccountNumber
INNER JOIN (
SELECT 
*
FROM userAccess
) AS D ON PivotT.ResponsibilityID = D.ResponsibilityID AND PivotT.DepartmentID = D.DepartmentID AND PivotT.InstitutionID = D.InstitutionID

);
GO

CREATE OR ALTER FUNCTION dbo.fn_OversightDraftUnscoped
(
    @FinancialYear varchar(10)
)
RETURNS TABLE
AS
RETURN
(




WITH glData AS ( 
SELECT 
FinancialYear, AccountID, AccountNumber, AccountDescription, substring( AccountNumber, 3, 5) AS AccountN, substring( AccountNumber, 9, 3) AS InstitutionID, substring( AccountNumber, 13, 3) AS ResponsibilityID, 
substring( AccountNumber, 17, 4) AS DepartmentID, FORMAT(TRXDate, 'MMM') AS MonthN, NetChange 
FROM [FinanceAutomationSystem].[Dbo].[0098AFinGLMaster] 
WHERE FinancialYear = @FinancialYear 
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
A.*, ISNULL(B.QTYShipped, 0) AS QtyShipped, (Quantity - ISNULL(B.QTYShipped, 0)) AS ActBalance, ROUND(((Quantity - ISNULL(B.QTYShipped, 0)) * UnitCost),2) AS ActCost 
FROM [FinanceAutomationSystem].[dbo].[0040DBudgetsEncumbrance] AS A 
LEFT JOIN ( 
SELECT 
* 
FROM [FinanceAutomationSystem].[dbo].[0098FPOShipmentDetails] 
) AS B ON A.LineNbr = B.POLineID AND A.PONumber = B.PONumber 
) AS A 
WHERE Status IN ('AP', 'PO', 'RT', 'HD', 'PN') AND 
CASE 
WHEN MONTH( CAST(ReqDateCreated AS DATE) ) >= 10 then YEAR( CAST(ReqDateCreated AS DATE) ) +1 
ELSE YEAR( CAST(ReqDateCreated AS DATE) ) 
END = @FinancialYear 
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
A.*, ISNULL(B.QTYShipped, 0) AS QtyShipped, (Quantity - ISNULL(B.QTYShipped, 0)) AS ActBalance, ROUND(((Quantity - ISNULL(B.QTYShipped, 0)) * UnitCost),2) AS ActCost 
FROM [FinanceAutomationSystem].[dbo].[0040DBudgetsEncumbrance] AS A 
LEFT JOIN ( 
SELECT 
* 
FROM [FinanceAutomationSystem].[dbo].[0098FPOShipmentDetails] 
) AS B ON A.LineNbr = B.POLineID AND A.PONumber = B.PONumber 
) AS A 
WHERE Status IN ('AP', 'PO', 'RT', 'HD', 'PN') AND 
CASE 
WHEN MONTH( CAST(ReqDateCreated AS DATE) ) >= 10 then YEAR( CAST(ReqDateCreated AS DATE) ) +1 
ELSE YEAR( CAST(ReqDateCreated AS DATE) ) 
END = @FinancialYear 

), 

--=========================================================================================================================================== End of Table 3

allocationData AS ( 
SELECT 
FinancialYear, AccountNumber, ROUND( SUM(Allocation) , 2) AS Allocation 
FROM [FinanceAutomationSystem].[Dbo].[0040CBudgetsAllocation] 
WHERE FinancialYear = @FinancialYear 
GROUP BY FinancialYear, AccountNumber 
), 

--=========================================================================================================================================== End of Table 4

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

--=========================================================================================================================================== End of Table 5

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

--=========================================================================================================================================== End of Table 6


--=========================================================================================================================================== End of Table 7


SELECT
FinancialYear, AccountID, PivotT.AccountNumber, PivotT.AccountDescription, AccountN, PivotT.InstitutionID, PivotT.ResponsibilityID, PivotT.DepartmentID,
ROUND(ISNULL(Oct, 0),2) AS Oct, ROUND(ISNULL(Nov, 0),2) AS Nov, ROUND(ISNULL(Dec, 0),2) AS Dec, 
ROUND((ISNULL(Oct, 0) + ISNULL(Nov, 0) + ISNULL(Dec, 0)),2) AS Q1, 
ROUND(ISNULL(Jan, 0),2) AS Jan, ROUND(ISNULL(Feb, 0),2) AS Feb, ROUND(ISNULL(Mar, 0),2) AS Mar, 
ROUND((ISNULL(Jan, 0) + ISNULL(Feb, 0) + ISNULL(Mar, 0)),2) AS Q2,
ROUND(ISNULL(Apr, 0),2) AS Apr, ROUND(ISNULL(May, 0),2) AS May, ROUND(ISNULL(Jun, 0),2) AS Jun, 
ROUND((ISNULL(Apr, 0) + ISNULL(May, 0) + ISNULL(Jun, 0)),2) AS Q3,
ROUND(ISNULL(Jul, 0),2) AS Jul, ROUND(ISNULL(Aug, 0),2) AS Aug, ROUND(ISNULL(Sep, 0),2) AS Sep, 
ROUND((ISNULL(Jul, 0) + ISNULL(Aug, 0) + ISNULL(Sep, 0)),2) AS Q4,
ROUND((ISNULL(Oct, 0) + ISNULL(Nov, 0) + ISNULL(Dec, 0) + ISNULL(Jan, 0) + ISNULL(Feb, 0) + ISNULL(Mar, 0) + ISNULL(Apr, 0) + ISNULL(May, 0) + ISNULL(Jun, 0) + ISNULL(Jul, 0) + ISNULL(Aug, 0) + ISNULL(Sep, 0) ),2) AS YTDTotal, 
ROUND((ISNULL(Oct, 0) + ISNULL(Nov, 0) + ISNULL(Dec, 0) + ISNULL(Jan, 0) + ISNULL(Feb, 0) + ISNULL(Mar, 0) + ISNULL(Apr, 0) + ISNULL(May, 0) + ISNULL(Jun, 0) + ISNULL(Jul, 0) + ISNULL(Aug, 0) + ISNULL(Sep, 0) + ISNULL(Approved,0) ),2) AS AcutalYTDExpense, 
ROUND(ISNULL(Allocation, 0),2) AS Allocation, ROUND(ISNULL(Approved,0),2) AS Approved, ROUND(ISNULL(Routing, 0),2) AS Routing, 
CASE 
WHEN ROUND(ISNULL(Allocation,0) - (ROUND((ISNULL(Oct, 0) + ISNULL(Nov, 0) + ISNULL(Dec, 0) + ISNULL(Jan, 0) + ISNULL(Feb, 0) + ISNULL(Mar, 0) + ISNULL(Apr, 0) + ISNULL(May, 0) + ISNULL(Jun, 0) + ISNULL(Jul, 0) + 
ISNULL(Aug, 0) + ISNULL(Sep, 0) ),2)), 2) < 0 then ABS(ROUND(ISNULL(Allocation,0) - (ROUND((ISNULL(Oct, 0) + ISNULL(Nov, 0) + ISNULL(Dec, 0) + ISNULL(Jan, 0) + ISNULL(Feb, 0) + ISNULL(Mar, 0) + ISNULL(Apr, 0) + ISNULL(May, 0) + 
ISNULL(Jun, 0) + ISNULL(Jul, 0) + ISNULL(Aug, 0) + ISNULL(Sep, 0) ),2)), 2)) 
ELSE 0 
END AS ExcessTotals, 
CASE 
WHEN ROUND(ISNULL(Allocation,0) - (ROUND((ISNULL(Oct, 0) + ISNULL(Nov, 0) + ISNULL(Dec, 0) + ISNULL(Jan, 0) + ISNULL(Feb, 0) + ISNULL(Mar, 0) + ISNULL(Apr, 0) + ISNULL(May, 0) + ISNULL(Jun, 0) + ISNULL(Jul, 0) + 
ISNULL(Aug, 0) + ISNULL(Sep, 0) ),2)), 2) > 0 then ROUND(ISNULL(Allocation,0) - (ROUND((ISNULL(Oct, 0) + ISNULL(Nov, 0) + ISNULL(Dec, 0) + ISNULL(Jan, 0) + ISNULL(Feb, 0) + ISNULL(Mar, 0) + ISNULL(Apr, 0) + ISNULL(May, 0) + 
ISNULL(Jun, 0) + ISNULL(Jul, 0) + ISNULL(Aug, 0) + ISNULL(Sep, 0) ),2)), 2) 
ELSE 0 
END AS TrueBalanceOfAllocation, B.ResponsibilityName, B.Cluster AS ClusterName, B.InstitutionName, B.DepartmentName 
FROM (
SELECT
*
FROM glData
WHERE NetChange <> 0

UNION ALL

SELECT
A.FinancialYear, B.AccountLineID AS AccountID, A.AccountNumber, B.AccountDescription, B.AccountSegment2 AS AccountN, B.AccountSegment3 AS InstitutionID, B.AccountSegment4 AS ResponsibilityID,
B.AccountSegment5 AS DepartmentID, 'Allocation' AS MonthN, Allocation AS NetChange
FROM allocationData AS A
LEFT JOIN (
SELECT 
*
FROM coaData
) AS B ON A.AccountNumber = B.AccountNumber
WHERE Allocation <> 0

UNION ALL

SELECT
A.FinYear AS FinancialYear, B.AccountLineID AS AccountID, A.GLAccount AS AccountNumber, B.AccountDescription, A.AccountN, A.InstitutionID, A.ResponsibilityID, A.DepartmentID, 
Details AS MonthN, Amount AS NetChange
FROM (
SELECT
FinYear, GLAccount, AccountN, InstitutionID, ResponsibilityID, DepartmentID, Details, Amount
FROM encumberanceData
UNPIVOT (
	Amount FOR Details IN (Approved, Routing)
) AS Unpivotted
) AS A
LEFT JOIN (
SELECT 
*
FROM coaData
) AS B ON A.GLAccount = B.AccountNumber
WHERE Amount <> 0
) AS AllConsolidated
PIVOT ( 
	SUM(NetChange) 
	FOR MonthN IN (Oct, Nov, Dec, Jan, Feb, Mar, Apr, May, Jun, Jul, Aug, Sep, Allocation, Approved, Routing)
) AS PivotT 
LEFT JOIN (
SELECT 
*
FROM coaData
) AS B ON PivotT.AccountNumber = B.AccountNumber
INNER JOIN (
SELECT
*
FROM varianceLines
) AS C ON PivotT.AccountN = C.AccountNumber

);
GO
