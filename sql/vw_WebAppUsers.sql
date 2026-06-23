/* =============================================================================
   View:  dbo.vw_WebAppUsers
   DB:    SWRHAExpenseControl

   Purpose:
     Auth / active-status source for the app (credential validation and the
     5-minute active reverification). Queried read-only via
     App\Models\GP\SWRHAExpenseControlUser and EnsureUserIsActive.

   Notes:
     1. Run this script against SQL Server.
     2. EmployeeName is sourced from [ArrearsDatabase].[dbo].[0002AEmployees]
        via a LEFT JOIN — a missing match yields NULL EmployeeName rather than
        dropping the user row, so authentication never breaks for an employee
        not present in the arrears DB.
     3. The join keys are forced to Latin1_General_CI_AS to avoid a collation
        conflict between the two databases.
     4. IsActive is the PascalCase column the app relies on — do NOT rename it.
   ============================================================================= */

USE [SWRHAExpenseControl];
GO

SET ANSI_NULLS ON;
GO

SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER VIEW [dbo].[vw_WebAppUsers]
AS
SELECT
    A.EmployeeID,
    B.EmployeeName,
    A.UserName,
    A.UserPassword,
    A.PositionID,
    A.IsActive
FROM [SWRHAExpenseControl].[dbo].[0006AWebAppControls] AS A
LEFT JOIN [ArrearsDatabase].[dbo].[0002AEmployees] AS B
    ON A.EmployeeID COLLATE Latin1_General_CI_AS = B.EmployeeID COLLATE Latin1_General_CI_AS;
GO
