This is the SQL script I want to work with:





-- Start Full Allocation Data Table
SELECT
A.FinancialYear, D.ClusterName, D.InstitutionName, E.SegmentDescription AS ResponsibilityName, F.SegmentDescription AS DepartmentName, C.AccountDescription, A.AccountNumber, A.TotalAllocation
FROM (

-- Start Connection to Main Allocation Table
SELECT
FinancialYear, AccountNumber, Round(Sum(Allocation) , 2 ) AS TotalAllocation
FROM [FinanceAutomationSystem].[dbo].[0040CBudgetsAllocation]
-- ************************************************************************************************There must be an element here to filter between financial Years eg. WHERE FinancialYear = '2026'
GROUP BY FinancialYear, AccountNumber
-- End Connection to Main Allocation Table
) AS A

INNER JOIN (
-- Start Filter User Department Access
SELECT
A.*, B.DepartmentID, B.ResponsibilityID, '-' + CAST(B.ResponsibilityID AS varchar(255) ) + '-' + CAST(B.DepartmentID AS varchar(255) ) AS DeptFilter
FROM (
SELECT
EmployeeID, UserName, PositionID
FROM [SWRHAExpenseControl].[dbo].[0006AWebAppControls]
WHERE UserName = 'FFIGUERA1' AND IsActive = 'TRUE'
) AS A

INNER JOIN (  
SELECT
*
FROM [SWRHAExpenseControl].[dbo].[0006CWebAppPostControls]
WHERE IsActive = 'TRUE'
) AS B ON A.PositionID = B.PositionID

-- End Filter User Department Access
) AS B ON A.AccountNumber COLLATE Latin1_General_CI_AS LIKE '%' + B.DeptFilter + '%' 

INNER JOIN (
-- Start link to Budget and GP combination for Variance Lines and Account Descriptions
SELECT
A.*, B.LineNumber, B.LineDescription, C.AccountNumber, D.SegmentDescription AS AccountDescription
FROM (
SELECT
LineID, ReportName
FROM [FinanceAutomationSystem].[Dbo].[0030ACOAReports]
WHERE LineID = 3
) AS A

INNER JOIN (
SELECT
*
FROM [FinanceAutomationSystem].[Dbo].[0030BCOAReportlines]
WHERE LineDescription NOT LIKE '%TOTAL%'
) AS B ON A.LineID = B.ReportID

INNER JOIN (
SELECT
*
FROM [FinanceAutomationSystem].[Dbo].[0030CCOAReportAccounts]
) AS C ON B.LineNumber = C.ReportingLineID

LEFT JOIN (
SELECT DISTINCT
[SGMTNUMB], UPPER( LTRIM( RTRIM( [SGMNTID] ) ) ) AS SegmentID, UPPER( LTRIM( RTRIM( [DSCRIPTN] ) ) ) AS SegmentDescription
FROM [GPSWRHA.SWRHA.CO.TT].[SWRHA].[dbo].[GL40200]
WHERE [SGMTNUMB] = '2' AND UPPER( LTRIM( RTRIM( [SGMNTID] ) ) ) <> ''
) AS D ON C.AccountNumber = D.SegmentID

-- End link to Budget and GP combination for Variance Lines and Account Descriptions
) AS C ON A.AccountNumber LIKE '%' + CAST(C.AccountNumber AS varchar(255) ) + '%'

-- Start Link to GP For Institution and Cluster Details 
LEFT JOIN (
SELECT
A.*, B.CLUSTER AS ClusterName, B.INSTITUTION AS InstitutionName
FROM (
SELECT DISTINCT
[SGMTNUMB], UPPER( LTRIM( RTRIM( [SGMNTID] ) ) ) AS SegmentID
FROM [GPSWRHA.SWRHA.CO.TT].[SWRHA].[dbo].[GL40200]
WHERE [SGMTNUMB] = '3' AND UPPER( LTRIM( RTRIM( [SGMNTID] ) ) ) <> ''
) AS A 

LEFT JOIN (
SELECT
*
FROM [GPSWRHA.SWRHA.CO.TT].[SWRHA].[dbo].[DBA_Clusters]
) AS B ON A.SegmentID = B.[INSTITUTION CODE]

-- End Link to GP For Institution and Cluster Details 
) AS D ON A.AccountNumber COLLATE Latin1_General_CI_AS LIKE '%-' + CAST(D.SegmentID AS varchar(255) ) + '-%'

-- Start Link to GP for Responsibility Details
LEFT JOIN (
SELECT DISTINCT
[SGMTNUMB], UPPER( LTRIM( RTRIM( [SGMNTID] ) ) ) AS SegmentID, UPPER( LTRIM( RTRIM( [DSCRIPTN] ) ) ) AS SegmentDescription
FROM [GPSWRHA.SWRHA.CO.TT].[SWRHA].[dbo].[GL40200]
WHERE [SGMTNUMB] = '4' AND UPPER( LTRIM( RTRIM( [SGMNTID] ) ) ) <> '' AND UPPER( LTRIM( RTRIM( [DSCRIPTN] ) ) ) <> ''

-- End Link to GP for Responsibility Details
) AS E ON A.AccountNumber COLLATE Latin1_General_CI_AS LIKE '%-' + CAST(E.SegmentID AS varchar(255) ) + '-%'

-- Start Link to GP for Department Details
LEFT JOIN (
SELECT DISTINCT
[SGMTNUMB], UPPER( LTRIM( RTRIM( [SGMNTID] ) ) ) AS SegmentID, UPPER( LTRIM( RTRIM( [DSCRIPTN] ) ) ) AS SegmentDescription
FROM [GPSWRHA.SWRHA.CO.TT].[SWRHA].[dbo].[GL40200]
WHERE [SGMTNUMB] = '5' AND UPPER( LTRIM( RTRIM( [SGMNTID] ) ) ) <> '' AND UPPER( LTRIM( RTRIM( [DSCRIPTN] ) ) ) <> ''

-- End Link to GP for Department Details
) AS F ON A.AccountNumber COLLATE Latin1_General_CI_AS LIKE '%-' + CAST(F.SegmentID AS varchar(255) ) + '-%'

-- End Full Allocation Data Table
ORDER BY A.FinancialYear ASC, D.ClusterName ASC, D.InstitutionName ASC, F.SegmentDescription ASC, A.AccountNumber ASC
