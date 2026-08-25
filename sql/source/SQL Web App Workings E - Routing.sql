



WITH glData AS ( 
SELECT 
FinancialYear, AccountID, AccountNumber, AccountDescription, substring( AccountNumber, 3, 5) AS AccountN, substring( AccountNumber, 9, 3) AS InstitutionID, substring( AccountNumber, 13, 3) AS ResponsibilityID, 
substring( AccountNumber, 17, 4) AS DepartmentID, FORMAT(TRXDate, 'MMM') AS MonthN, NetChange 
FROM [FinanceAutomationSystem].[Dbo].[0098AFinGLMaster] 
WHERE FinancialYear = '2026'  --====================================Needs to be filterable
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
END = '2026' --====================================Needs to be filterable 
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
END = '2026' --====================================Needs to be filterable

), 

--=========================================================================================================================================== End of Table 2

allocationData AS ( 
SELECT 
FinancialYear, AccountNumber, ROUND( SUM(Allocation) , 2) AS Allocation 
FROM [FinanceAutomationSystem].[Dbo].[0040CBudgetsAllocation] 
WHERE FinancialYear = '2026'  --====================================Needs to be filterable
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
), 

--=========================================================================================================================================== End of Table 5

userAccess AS ( 
SELECT 
A.EmployeeID, C.EmployeeName, A.UserName, A.PositionID, A.IsActive, B.DepartmentID, B.ResponsibilityID
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
WHERE B.DepartmentID IS NOT NULL AND C.EmployeeName = 'FRANCIS FIGUERA'  --====================================Needs to be filterable
) 

--=========================================================================================================================================== End of Table 5

SELECT
A.RequisitionNumber, A.PONumber, A.StatusName, A.LineNbr, A.ItemDescription, A.AccountDescription, A.ReqDateCreated, A.UofM, A.ActBalance AS Quantity, A.UnitCost, A.ActCost AS ExtendedCost, 
A.Cluster, A.Institution, A.Department, A.ResponsibilityCentre, A.VendorName, A.FinYear
FROM encumberanceDetails AS A
INNER JOIN (
SELECT 
*
FROM userAccess
) AS B ON A.ResponsibilityID = B.ResponsibilityID AND A.DepartmentID = B.DepartmentID
WHERE A.Status IN ('RT', 'HD', 'PN')

