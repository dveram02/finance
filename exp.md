I want you to help me a build a view in my sqlserver for the relevant database. Think hard and create the view.

THis is the script:



-- Start Completed HOD Report tied to specific user login
SELECT
A.AccountNumber, A.PeriodID, A.TRXPeriod, A.AccountDescription, A.NetChange, B.LineNumber, B.LineDescription, B.Part1 AS MainGroup, B.Part2 AS SubGroupA, B.Part3 AS SubGroupB, D.ClusterName, D.InstitutionName, E.SegmentDescription AS Responsibility
FROM (
-- Start Finance GL Master that incorporates all correcting entries
SELECT
FinancialYear, PeriodID, TRXPeriod, AccountNumber, AccountDescription, ROUND(SUM(NetChange), 2) AS NetChange
FROM (
SELECT 
FinancialYear, TRXDate, AccountNumber, AccountDescription, NetChange, UPPER(FORMAT(CAST(TRXDATE AS date), 'MMM, yy')) AS TRXPeriod,
CASE 
WHEN Month(TRXDATE) = 10 then 1
WHEN Month(TRXDATE) = 11 then 2
WHEN Month(TRXDATE) = 12 then 3
WHEN Month(TRXDATE) = 1 then 4
WHEN Month(TRXDATE) = 2 then 5
WHEN Month(TRXDATE) = 3 then 6
WHEN Month(TRXDATE) = 4 then 7
WHEN Month(TRXDATE) = 5 then 8
WHEN Month(TRXDATE) = 6 then 9
WHEN Month(TRXDATE) = 7 then 10
WHEN Month(TRXDATE) = 8 then 11
WHEN Month(TRXDATE) = 9 then 12
END AS PeriodID
FROM [FinanceAutomationSystem].[Dbo].[0098AFinGLMaster]
WHERE FinancialYear = '2026' --============================================================================================================> This MUST be dynamic to select relevant Financial Year!
) AS A 
GROUP BY FinancialYear, PeriodID, TRXPeriod, AccountNumber, AccountDescription
-- End Finance GL Master that incorporates all correcting entries
) AS A

INNER JOIN (
-- Start link to Budget and GP combination for Variance Lines and Account Descriptions
SELECT
A.*, B.LineNumber, B.LineDescription, B.Part1, B.Part2, B.Part3, C.AccountNumber, D.SegmentDescription AS AccountDescription
FROM (
SELECT
LineID, ReportName
FROM [FinanceAutomationSystem].[Dbo].[0030ACOAReports]
WHERE LineID = 3
) AS A

INNER JOIN (
SELECT
LineID, ReportID, LineNumber, LineDescription,
LTRIM(RTRIM(PARSENAME(REPLACE(REPLACE(LineDescription, '.', ' '), ' : ', ' . '), (LEN(LineDescription) - LEN(REPLACE(LineDescription, ':', '')) + 1) ) ) ) AS Part1,
LTRIM(RTRIM(PARSENAME(REPLACE(REPLACE(LineDescription, '.', ' '), ' : ', ' . '), (LEN(LineDescription) - LEN(REPLACE(LineDescription, ':', ''))) ) ) ) AS Part2,
LTRIM(RTRIM(PARSENAME(REPLACE(REPLACE(LineDescription, '.', ' '), ' : ', ' . '), (LEN(LineDescription) - LEN(REPLACE(LineDescription, ':', '')) - 1) ) ) ) AS Part3
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
) AS B ON A.AccountNumber LIKE '%' + CAST(B.AccountNumber AS varchar(255) ) + '%'

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
) AS C ON A.AccountNumber COLLATE Latin1_General_CI_AS LIKE '%' + DeptFilter + '%' 


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

-- End Completed HOD Report tied to specific user login

ORDER BY PeriodID ASC, InstitutionName ASC, Responsibility ASC, LineNumber ASC


