


WITH 
--Table1
glData AS (
SELECT
FinancialYear, AccountID, AccountNumber, AccountDescription, substring( AccountNumber, 3, 5) AS AccountN, substring( AccountNumber, 9, 3) AS InstitutionID, substring( AccountNumber, 13, 3) AS ResponsibilityID , 
substring( AccountNumber, 17, 4) AS DepartmentID, 
FORMAT(TRXDate, 'MMM') AS MonthN, NetChange
FROM [FinanceAutomationSystem].[dbo].[0098AFinGLMaster]
WHERE FinancialYear = '2025'  --================================================================= The Financial Year needs to be filterable
),
--==================================================================================================================================================================End of Table 1
-- Table2
encumberanceData AS (
SELECT
FinYear, GLAccount, InstitutionID, ResponsibilityID, DepartmentID, 
ROUND(ISNULL(AP, 0), 2) AS AP, ROUND(ISNULL(PO, 0), 2) AS PO, ROUND((ISNULL(AP, 0) + ISNULL(PO, 0)), 2) AS Approved,  
ROUND(ISNULL(RT, 0), 2) AS RT, ROUND(ISNULL(HD, 0), 2) AS HD, ROUND(ISNULL(PN, 0), 2) AS PN, ROUND((ISNULL(RT, 0) + ISNULL(HD, 0) + ISNULL(PN, 0)), 2) AS Routing  
FROM (
SELECT
GLAccount, Status, ExtendedCost, 
CASE
WHEN MONTH( CAST(ReqDateCreated AS DATE) ) >= 10 then YEAR( CAST(ReqDateCreated AS DATE) ) +1
ELSE YEAR( CAST(ReqDateCreated AS DATE) )
END AS FinYear, substring( GLAccount, 9, 3) AS InstitutionID , substring( GLAccount, 13, 3) AS ResponsibilityID , substring( GLAccount, 17, 4) AS DepartmentID
FROM [FinanceAutomationSystem].[dbo].[0040DBudgetsEncumbrance]
WHERE Status IN ('AP', 'PO', 'RT', 'HD', 'PN') AND 
CASE
WHEN MONTH( CAST(ReqDateCreated AS DATE) ) >= 10 then YEAR( CAST(ReqDateCreated AS DATE) ) +1
ELSE YEAR( CAST(ReqDateCreated AS DATE) )
END = '2025' --================================================================= The Financial Year needs to be filterable
) AS A
PIVOT ( SUM(ExtendedCost)
	FOR Status IN (AP, PO, RT, HD, PN)) AS PivotT
),
--==================================================================================================================================================================End of Table 2
--Table3
allocationData AS (
SELECT
FinancialYear, AccountNumber, ROUND( SUM(Allocation) , 2) AS Allocation
FROM [FinanceAutomationSystem].[dbo].[0040CBudgetsAllocation]
WHERE FinancialYear = '2025' --================================================================= The Financial Year needs to be filterable
GROUP BY FinancialYear, AccountNumber
),
--==================================================================================================================================================================End of Table 3
--Table 4
coaData AS (
SELECT
UPPER( LTRIM( RTRIM( ACTINDX ) ) ) AS AccountLineID,
UPPER( LTRIM( RTRIM( ACTNUMBR_1 ) ) ) AS AccountSegment1, UPPER( LTRIM( RTRIM( ACTNUMBR_2 ) ) ) AS AccountSegment2, UPPER( LTRIM( RTRIM( ACTNUMBR_3 ) ) ) AS AccountSegment3,
UPPER( LTRIM( RTRIM( ACTNUMBR_4 ) ) ) AS AccountSegment4, UPPER( LTRIM( RTRIM( ACTNUMBR_5 ) ) ) AS AccountSegment5, UPPER( LTRIM( RTRIM( ACTNUMBR_6 ) ) ) AS AccountSegment6,
UPPER( LTRIM( RTRIM( ACTNUMBR_7 ) ) ) AS AccountSegment7,
UPPER( LTRIM( RTRIM( ACTNUMBR_1 ) ) ) + '-' + UPPER( LTRIM( RTRIM( ACTNUMBR_2 ) ) ) + '-' + UPPER( LTRIM( RTRIM( ACTNUMBR_3 ) ) ) + '-' + UPPER( LTRIM( RTRIM( ACTNUMBR_4 ) ) )
+ '-' + UPPER( LTRIM( RTRIM( ACTNUMBR_5 ) ) )  + '-' + UPPER( LTRIM( RTRIM( ACTNUMBR_6 ) ) ) + '-' + UPPER( LTRIM( RTRIM( ACTNUMBR_7 ) ) ) AS AccountNumber,
UPPER( LTRIM( RTRIM( ACTDESCR ) ) ) AS AccountDescription,
CASE WHEN B.RevisedDescription IS NULL THEN 'UNDEFINED' ELSE B.RevisedDescription END AS ResponsibilityName, C.Cluster,
CASE WHEN C.RevisedDescription IS NULL THEN 'UNDEFINED' ELSE C.RevisedDescription END AS InstitutionName,
CASE WHEN D.RevisedDescription IS NULL THEN 'UNDEFINED' ELSE D.RevisedDescription END AS DepartmentName
FROM [GPSWRHA.SWRHA.CO.TT].[SWRHA].[dbo].[GL00100] AS A 
LEFT JOIN (
SELECT
UPPER( LTRIM( RTRIM( SGMTNUMB ) ) ) AS SegmentNumber, UPPER( LTRIM( RTRIM( SGMNTID ) ) ) AS SegmentID, UPPER( LTRIM( RTRIM( DSCRIPTN ) ) ) AS SegmentDescription, B.RevisedDescription
FROM [GPSWRHA.SWRHA.CO.TT].[SWRHA].[dbo].[GL40200] AS A
LEFT JOIN (
SELECT
SegmentNumber , SegmentID, RevisedDescription
FROM [FinanceAutomationSystem].[dbo].[0000CSegmentControls]
) AS B ON UPPER( LTRIM( RTRIM( A.SGMTNUMB ) ) ) COLLATE Latin1_General_CI_AS = B.SegmentNumber AND UPPER( LTRIM( RTRIM( A.SGMNTID ) ) ) COLLATE Latin1_General_CI_AS = B.SegmentID
WHERE UPPER( LTRIM( RTRIM( SGMTNUMB ) ) ) = 4  AND UPPER( LTRIM( RTRIM( B.RevisedDescription ) ) ) <> 'REMOVE'
) AS B ON UPPER( LTRIM( RTRIM( ACTNUMBR_4 ) ) ) = B.SegmentID
LEFT JOIN (
SELECT
UPPER( LTRIM( RTRIM( SGMTNUMB ) ) ) AS SegmentNumber, UPPER( LTRIM( RTRIM( SGMNTID ) ) ) AS SegmentID, UPPER( LTRIM( RTRIM( DSCRIPTN ) ) ) AS SegmentDescription, B.RevisedDescription, C.Cluster
FROM [GPSWRHA.SWRHA.CO.TT].[SWRHA].[dbo].[GL40200] AS A
LEFT JOIN (
SELECT
SegmentNumber , SegmentID, RevisedDescription
FROM [FinanceAutomationSystem].[dbo].[0000CSegmentControls]
) AS B ON UPPER( LTRIM( RTRIM( A.SGMTNUMB ) ) ) COLLATE Latin1_General_CI_AS = B.SegmentNumber AND UPPER( LTRIM( RTRIM( A.SGMNTID ) ) ) COLLATE Latin1_General_CI_AS = B.SegmentID
LEFT JOIN (
SELECT
UPPER( LTRIM( RTRIM( CLUSTER ) ) ) AS Cluster, UPPER( LTRIM( RTRIM( INSTITUTION ) ) ) AS InstitutionName, UPPER( LTRIM( RTRIM( [INSTITUTION CODE] ) ) ) AS InstitutionCode
FROM [GPSWRHA.SWRHA.CO.TT].[SWRHA].[dbo].[DBA_Clusters]
) AS C ON UPPER( LTRIM( RTRIM( A.SGMNTID ) ) ) COLLATE Latin1_General_CI_AS = C.InstitutionCode
WHERE UPPER( LTRIM( RTRIM( SGMTNUMB ) ) ) = 3 AND UPPER( LTRIM( RTRIM( B.RevisedDescription ) ) ) <> 'REMOVE'
) AS C ON UPPER( LTRIM( RTRIM( ACTNUMBR_3 ) ) ) = C.SegmentID
LEFT JOIN (
SELECT
UPPER( LTRIM( RTRIM( SGMTNUMB ) ) ) AS SegmentNumber, UPPER( LTRIM( RTRIM( SGMNTID ) ) ) AS SegmentID, UPPER( LTRIM( RTRIM( DSCRIPTN ) ) ) AS SegmentDescription, B.RevisedDescription
FROM [GPSWRHA.SWRHA.CO.TT].[SWRHA].[dbo].[GL40200] AS A
LEFT JOIN (
SELECT
SegmentNumber , SegmentID, RevisedDescription
FROM [FinanceAutomationSystem].[dbo].[0000CSegmentControls]
) AS B ON UPPER( LTRIM( RTRIM( A.SGMTNUMB ) ) ) COLLATE Latin1_General_CI_AS = B.SegmentNumber AND UPPER( LTRIM( RTRIM( A.SGMNTID ) ) ) COLLATE Latin1_General_CI_AS = B.SegmentID
WHERE UPPER( LTRIM( RTRIM( SGMTNUMB ) ) ) = 5 AND UPPER( LTRIM( RTRIM( B.RevisedDescription ) ) ) <> 'REMOVE'
) AS D ON UPPER( LTRIM( RTRIM( ACTNUMBR_5 ) ) ) = D.SegmentID
),
--==================================================================================================================================================================End of Table 4
-- Table5
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
LineID, ReportID, LineNumber, LineDescription,
LTRIM(RTRIM(PARSENAME(REPLACE(REPLACE(LineDescription, '.', ' '), ' : ', ' . '), (LEN(LineDescription) - LEN(REPLACE(LineDescription, ':', '')) + 1) ) ) ) AS Part1,
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
--==================================================================================================================================================================End of Table 5
-- Table6
userControls AS (
SELECT
A.*, B.DepartmentID, B.ResponsibilityID, '-' + CAST(B.ResponsibilityID AS varchar(255) ) + '-' + CAST(B.DepartmentID AS varchar(255) ) AS DeptFilter
FROM (
SELECT
EmployeeID, UserName, PositionID
FROM [SWRHAExpenseControl].[dbo].[0006AWebAppControls]
WHERE UserName = 'FFIGUERA1' AND IsActive = 'TRUE' --================================================================= The user name needs to be filtered
) AS A

INNER JOIN (  
SELECT
*
FROM [SWRHAExpenseControl].[dbo].[0006CWebAppPostControls]
WHERE IsActive = 'TRUE'
) AS B ON A.PositionID = B.PositionID
)
--==================================================================================================================================================================End of Table 6


SELECT
A.*, ISNULL(B.Approved, 0) AS Approved, ISNULL(B.Routing, 0) AS Routing, ROUND((A.YTDTotal + ISNULL(B.Approved, 0)+ ISNULL(B.Routing, 0)), 2) AS ActualExpenditure, ISNULL(C.Allocation,0) AS Allocation, 
CASE
WHEN ROUND(ISNULL(C.Allocation,0) - (A.YTDTotal + ISNULL(B.Approved, 0)+ ISNULL(B.Routing, 0)), 2) < 0 then ABS(ROUND(ISNULL(C.Allocation,0) - (A.YTDTotal + ISNULL(B.Approved, 0)+ ISNULL(B.Routing, 0)), 2))
ELSE 0
END AS Excess,
CASE
WHEN ROUND(ISNULL(C.Allocation,0) - (A.YTDTotal + ISNULL(B.Approved, 0) + ISNULL(B.Routing, 0)), 2) > 0 then ROUND(ISNULL(C.Allocation,0) - (A.YTDTotal + ISNULL(B.Approved, 0)+ ISNULL(B.Routing, 0)), 2)
ELSE 0
END AS AllocationBalance, D.Cluster, D.InstitutionName, D.ResponsibilityName, D.DepartmentName
FROM (
SELECT
FinancialYear, AccountID, AccountNumber, AccountDescription, AccountN, InstitutionID, ResponsibilityID, DepartmentID, 
ROUND(ISNULL(Oct, 0), 2) AS Oct, ROUND(ISNULL(Nov, 0), 2) AS Nov, ROUND(ISNULL(Dec, 0), 2) AS Dec, 
ROUND((ISNULL(Oct, 0)+ISNULL(Nov, 0)+ISNULL(Dec, 0)), 2) AS Q1,
ROUND(ISNULL(Jan, 0), 2) AS Jan, ROUND(ISNULL(Feb, 0), 2) AS Feb, ROUND(ISNULL(Mar, 0), 2) AS Mar, 
ROUND((ISNULL(Jan, 0)+ISNULL(Feb, 0)+ISNULL(Mar, 0)), 2) AS Q2,
ROUND(ISNULL(Apr, 0), 2) AS Apr, ROUND(ISNULL(May, 0), 2) AS May, ROUND(ISNULL(Jun, 0), 2) AS Jun, 
ROUND((ISNULL(Apr, 0)+ISNULL(May, 0)+ISNULL(Jun, 0)), 2) AS Q3,
ROUND(ISNULL(Jul, 0), 2) AS Jul, ROUND(ISNULL(Aug, 0), 2) AS Aug, ROUND(ISNULL(Sep, 0), 2) AS Sep,
ROUND((ISNULL(Jul, 0)+ISNULL(Aug, 0)+ISNULL(Sep, 0)), 2) AS Q4,
ROUND((ISNULL(Oct, 0)+ISNULL(Nov, 0)+ISNULL(Dec, 0)+ISNULL(Jan, 0)+ISNULL(Feb, 0)+ISNULL(Mar, 0)+ISNULL(Apr, 0)+ISNULL(May, 0)+ISNULL(Jun, 0)+ISNULL(Jul, 0)+ISNULL(Aug, 0)+ISNULL(Sep, 0)), 2)AS YTDTotal
FROM glData
PIVOT ( SUM(NetChange)
	FOR MonthN IN (Oct, Nov, Dec, Jan, Feb, Mar, Apr, May, Jun, Jul, Aug, Sep)) AS PivotT
) AS A
LEFT JOIN encumberanceData AS B ON A.FinancialYear = B.FinYear AND A.AccountNumber = B.GLAccount
LEFT JOIN allocationData AS C ON A.AccountNumber = C.AccountNumber AND A.FinancialYear = C.FinancialYear
LEFT JOIN coaData AS D ON A.AccountID = D.AccountLineID
INNER JOIN varianceLines AS E ON A.AccountN = E.AccountNumber
INNER JOIN userControls AS F ON D.AccountSegment5 COLLATE Latin1_General_CI_AS = F.DepartmentID AND D.AccountSegment4 COLLATE Latin1_General_CI_AS = F.ResponsibilityID
ORDER BY A.InstitutionID ASC, A.ResponsibilityID ASC, A.DepartmentID ASC, A.AccountNumber ASC





