/* =============================================================================
   View:  dbo.MonthlyExpenditure
   DB:    FinanceAutomationSystem

   Copy/paste notes:
     1. Run this script against SQL Server.
     2. The view is created in [FinanceAutomationSystem].
     3. The view is NOT parameterised (views can't be). Both dynamic values are
        exposed as columns and filtered by the app at query time:
          * FinancialYear -> WHERE FinancialYear = <resolved fiscal year>
          * UserName      -> WHERE UserName      = '<logged-in username>'
        The fiscal year is resolved app-side (App\Concerns\ResolvesFiscalYear),
        so historical years and prev/next navigation keep working. Do NOT bake
        GETDATE() into the view — that would lock it to the current FY only.

   Example query:
     SELECT *
     FROM [FinanceAutomationSystem].[dbo].[MonthlyExpenditure]
     WHERE FinancialYear = '2026'
       AND UserName      = '<logged-in username>'
     ORDER BY PeriodID, InstitutionName, Responsibility, LineNumber;
   ============================================================================= */

USE [FinanceAutomationSystem];
GO

CREATE OR ALTER VIEW [dbo].[MonthlyExpenditure]
AS
WITH FinGLMaster AS (
    SELECT
        GL.FinancialYear,
        CASE
            WHEN MONTH(GL.TRXDate) = 10 THEN 1
            WHEN MONTH(GL.TRXDate) = 11 THEN 2
            WHEN MONTH(GL.TRXDate) = 12 THEN 3
            WHEN MONTH(GL.TRXDate) = 1 THEN 4
            WHEN MONTH(GL.TRXDate) = 2 THEN 5
            WHEN MONTH(GL.TRXDate) = 3 THEN 6
            WHEN MONTH(GL.TRXDate) = 4 THEN 7
            WHEN MONTH(GL.TRXDate) = 5 THEN 8
            WHEN MONTH(GL.TRXDate) = 6 THEN 9
            WHEN MONTH(GL.TRXDate) = 7 THEN 10
            WHEN MONTH(GL.TRXDate) = 8 THEN 11
            WHEN MONTH(GL.TRXDate) = 9 THEN 12
        END AS PeriodID,
        -- TRXPeriod e.g. 'OCT, 25'. Built with a CASE map + 2-digit year instead
        -- of FORMAT(): FORMAT is per-row slow and culture-dependent; this is
        -- deterministic and sargable-friendly.
        CASE MONTH(GL.TRXDate)
            WHEN 1 THEN 'JAN' WHEN 2 THEN 'FEB' WHEN 3 THEN 'MAR'
            WHEN 4 THEN 'APR' WHEN 5 THEN 'MAY' WHEN 6 THEN 'JUN'
            WHEN 7 THEN 'JUL' WHEN 8 THEN 'AUG' WHEN 9 THEN 'SEP'
            WHEN 10 THEN 'OCT' WHEN 11 THEN 'NOV' WHEN 12 THEN 'DEC'
        END + ', ' + RIGHT(CONVERT(varchar(4), YEAR(GL.TRXDate)), 2) AS TRXPeriod,
        GL.AccountNumber,
        GL.AccountDescription,
        ROUND(SUM(GL.NetChange), 2) AS NetChange
    FROM [FinanceAutomationSystem].[dbo].[0098AFinGLMaster] AS GL
    GROUP BY
        GL.FinancialYear,
        CASE
            WHEN MONTH(GL.TRXDate) = 10 THEN 1
            WHEN MONTH(GL.TRXDate) = 11 THEN 2
            WHEN MONTH(GL.TRXDate) = 12 THEN 3
            WHEN MONTH(GL.TRXDate) = 1 THEN 4
            WHEN MONTH(GL.TRXDate) = 2 THEN 5
            WHEN MONTH(GL.TRXDate) = 3 THEN 6
            WHEN MONTH(GL.TRXDate) = 4 THEN 7
            WHEN MONTH(GL.TRXDate) = 5 THEN 8
            WHEN MONTH(GL.TRXDate) = 6 THEN 9
            WHEN MONTH(GL.TRXDate) = 7 THEN 10
            WHEN MONTH(GL.TRXDate) = 8 THEN 11
            WHEN MONTH(GL.TRXDate) = 9 THEN 12
        END,
        CASE MONTH(GL.TRXDate)
            WHEN 1 THEN 'JAN' WHEN 2 THEN 'FEB' WHEN 3 THEN 'MAR'
            WHEN 4 THEN 'APR' WHEN 5 THEN 'MAY' WHEN 6 THEN 'JUN'
            WHEN 7 THEN 'JUL' WHEN 8 THEN 'AUG' WHEN 9 THEN 'SEP'
            WHEN 10 THEN 'OCT' WHEN 11 THEN 'NOV' WHEN 12 THEN 'DEC'
        END + ', ' + RIGHT(CONVERT(varchar(4), YEAR(GL.TRXDate)), 2),
        GL.AccountNumber,
        GL.AccountDescription
),
ReportLines AS (
    SELECT
        R.LineID,
        R.ReportName,
        L.LineNumber,
        L.LineDescription,
        LTRIM(RTRIM(PARSENAME(REPLACE(REPLACE(L.LineDescription, '.', ' '), ' : ', ' . '), (LEN(L.LineDescription) - LEN(REPLACE(L.LineDescription, ':', '')) + 1)))) AS Part1,
        LTRIM(RTRIM(PARSENAME(REPLACE(REPLACE(L.LineDescription, '.', ' '), ' : ', ' . '), (LEN(L.LineDescription) - LEN(REPLACE(L.LineDescription, ':', '')))))) AS Part2,
        LTRIM(RTRIM(PARSENAME(REPLACE(REPLACE(L.LineDescription, '.', ' '), ' : ', ' . '), (LEN(L.LineDescription) - LEN(REPLACE(L.LineDescription, ':', '')) - 1)))) AS Part3,
        A.AccountNumber,
        S.SegmentDescription AS AccountSegmentDescription
    FROM [FinanceAutomationSystem].[dbo].[0030ACOAReports] AS R
    INNER JOIN [FinanceAutomationSystem].[dbo].[0030BCOAReportlines] AS L
        ON R.LineID = L.ReportID
    INNER JOIN [FinanceAutomationSystem].[dbo].[0030CCOAReportAccounts] AS A
        ON L.LineNumber = A.ReportingLineID
    LEFT JOIN (
        SELECT DISTINCT
            UPPER(LTRIM(RTRIM([SGMNTID]))) AS SegmentID,
            UPPER(LTRIM(RTRIM([DSCRIPTN]))) AS SegmentDescription
        FROM [GPSWRHA.SWRHA.CO.TT].[SWRHA].[dbo].[GL40200]
        WHERE [SGMTNUMB] = '2'
            AND UPPER(LTRIM(RTRIM([SGMNTID]))) <> ''
    ) AS S
        ON CAST(A.AccountNumber AS varchar(255)) COLLATE Latin1_General_CI_AS = S.SegmentID COLLATE Latin1_General_CI_AS
    WHERE R.LineID = 3
        AND L.LineDescription NOT LIKE '%TOTAL%'
),
UserDepartmentAccess AS (
    SELECT
        U.EmployeeID,
        U.UserName,
        U.PositionID,
        P.DepartmentID,
        P.ResponsibilityID
    FROM [SWRHAExpenseControl].[dbo].[0006AWebAppControls] AS U
    INNER JOIN [SWRHAExpenseControl].[dbo].[0006CWebAppPostControls] AS P
        ON U.PositionID = P.PositionID
    WHERE U.IsActive = 'TRUE'
        AND P.IsActive = 'TRUE'
),
InstitutionDetails AS (
    SELECT
        S.SegmentID,
        C.CLUSTER AS ClusterName,
        C.INSTITUTION AS InstitutionName
    FROM (
        SELECT DISTINCT
            UPPER(LTRIM(RTRIM([SGMNTID]))) AS SegmentID
        FROM [GPSWRHA.SWRHA.CO.TT].[SWRHA].[dbo].[GL40200]
        WHERE [SGMTNUMB] = '3'
            AND UPPER(LTRIM(RTRIM([SGMNTID]))) <> ''
    ) AS S
    LEFT JOIN [GPSWRHA.SWRHA.CO.TT].[SWRHA].[dbo].[DBA_Clusters] AS C
        ON S.SegmentID COLLATE Latin1_General_CI_AS = C.[INSTITUTION CODE] COLLATE Latin1_General_CI_AS
),
ResponsibilityDetails AS (
    SELECT DISTINCT
        UPPER(LTRIM(RTRIM([SGMNTID]))) AS SegmentID,
        UPPER(LTRIM(RTRIM([DSCRIPTN]))) AS SegmentDescription
    FROM [GPSWRHA.SWRHA.CO.TT].[SWRHA].[dbo].[GL40200]
    WHERE [SGMTNUMB] = '4'
        AND UPPER(LTRIM(RTRIM([SGMNTID]))) <> ''
        AND UPPER(LTRIM(RTRIM([DSCRIPTN]))) <> ''
)
SELECT
    GL.FinancialYear,
    UDA.UserName,
    GL.AccountNumber,
    GL.PeriodID,
    GL.TRXPeriod,
    GL.AccountDescription,
    GL.NetChange,
    RL.LineNumber,
    RL.LineDescription,
    RL.Part1 AS MainGroup,
    RL.Part2 AS SubGroupA,
    RL.Part3 AS SubGroupB,
    I.ClusterName,
    I.InstitutionName,
    R.SegmentDescription AS Responsibility
FROM FinGLMaster AS GL
-- Split the dash-delimited AccountNumber ONCE into its segments, then join on
-- equality instead of four non-sargable LIKE '%...%' scans. Layout:
--   {prefix}-{account}-{institution}-{responsibility}-{department}-{..}-{..}
--   e.g. 4 - 80400 - H01 - 107 - 1157 - 00 - 000
-- NULLIF(...,0) makes a malformed account (missing dash) yield NULL segments,
-- which simply don't match (same outcome as the old LIKE), without raising an
-- "invalid length" error from SUBSTRING.
CROSS APPLY (SELECT NULLIF(CHARINDEX('-', GL.AccountNumber), 0) AS d1) AS p1
CROSS APPLY (SELECT NULLIF(CHARINDEX('-', GL.AccountNumber, p1.d1 + 1), 0) AS d2) AS p2
CROSS APPLY (SELECT NULLIF(CHARINDEX('-', GL.AccountNumber, p2.d2 + 1), 0) AS d3) AS p3
CROSS APPLY (SELECT NULLIF(CHARINDEX('-', GL.AccountNumber, p3.d3 + 1), 0) AS d4) AS p4
CROSS APPLY (SELECT NULLIF(CHARINDEX('-', GL.AccountNumber, p4.d4 + 1), 0) AS d5) AS p5
CROSS APPLY (
    SELECT
        LTRIM(RTRIM(SUBSTRING(GL.AccountNumber, p1.d1 + 1, p2.d2 - p1.d1 - 1))) AS AccountSeg,
        LTRIM(RTRIM(SUBSTRING(GL.AccountNumber, p2.d2 + 1, p3.d3 - p2.d2 - 1))) AS InstitutionSeg,
        LTRIM(RTRIM(SUBSTRING(GL.AccountNumber, p3.d3 + 1, p4.d4 - p3.d3 - 1))) AS ResponsibilitySeg,
        LTRIM(RTRIM(SUBSTRING(GL.AccountNumber, p4.d4 + 1, p5.d5 - p4.d4 - 1))) AS DepartmentSeg
) AS seg
INNER JOIN ReportLines AS RL
    ON CAST(RL.AccountNumber AS varchar(255)) COLLATE Latin1_General_CI_AS
       = seg.AccountSeg COLLATE Latin1_General_CI_AS
INNER JOIN UserDepartmentAccess AS UDA
    ON CAST(UDA.ResponsibilityID AS varchar(255)) COLLATE Latin1_General_CI_AS = seg.ResponsibilitySeg COLLATE Latin1_General_CI_AS
   AND CAST(UDA.DepartmentID    AS varchar(255)) COLLATE Latin1_General_CI_AS = seg.DepartmentSeg     COLLATE Latin1_General_CI_AS
LEFT JOIN InstitutionDetails AS I
    ON I.SegmentID COLLATE Latin1_General_CI_AS = seg.InstitutionSeg COLLATE Latin1_General_CI_AS
LEFT JOIN ResponsibilityDetails AS R
    ON R.SegmentID COLLATE Latin1_General_CI_AS = seg.ResponsibilitySeg COLLATE Latin1_General_CI_AS;
GO
