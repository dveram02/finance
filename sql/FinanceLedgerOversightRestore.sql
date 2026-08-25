/* ===========================================================================
   FinanceLedgerOversightRestore.sql
   ---------------------------------------------------------------------------
   Rolls the 2026-08-25 Oversight rollout back, using the copies taken by
   sql/FinanceLedgerOversightBackup.sql. Minutes, not the ~43 minutes a full
   source rebuild would cost.

   *** THIS IS NOT sql/FinanceLedgerRollback.sql. ***
   That script tears down the ENTIRE ledger subsystem - it drops the views,
   both procs, the function and all three tables. It is the undo for the
   original migration, not for this revision. Using it here would remove far
   more than you meant to.

   ROLLBACK TRIGGERS (any one):
     - an active user's accessible account count drops to ZERO. Note a large
       REDUCTION is expected and correct: the three-way access join closes a
       measured cross-institution exposure. Only zero signals failure.
     - snapshot Allocation, YTDTotal or account count moved at all (they must
       not - this change alters neither).
     - UNDEFINED label share above the agreed threshold.
     - Approved/Routing movement that cannot be attributed to shipment netting.

   ORDER MATTERS. Views come back before data: the app reads through the views,
   so restoring the old two-way access rule first stops the new (narrower) rule
   being applied to old figures.

   AFTER running this, also:
     1. git revert the application commit and re-run `npm run build`
        (public/build is gitignored - there is no artifact to restore);
     2. php artisan cache:clear file;
     3. re-enable the SQL Agent job if it was disabled.

   The three additive FinanceLedgerRefresh columns (TotalApproved,
   TotalRouting, UndefinedLabelPct) are deliberately LEFT IN PLACE. They are
   nullable-with-default and harmless; dropping them is a separate, reviewed
   DDL step, and the pre-Oversight backup does not carry them.
   =========================================================================== */

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

/* ---- guards -------------------------------------------------------------- */
IF OBJECT_ID('dbo.FinanceLedgerSnapshot_PreOversight', 'U') IS NULL
    THROW 51220, 'REFUSED: no pre-Oversight backup exists. Nothing to restore from - run the backup script BEFORE the rollout, not after.', 1;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.FinanceLedgerSnapshot_PreOversight)
    THROW 51221, 'REFUSED: the pre-Oversight snapshot copy is empty. Restoring it would leave the application with no data at all.', 1;
GO

IF NOT EXISTS (SELECT 1 FROM dbo.FinanceLedgerDefs_PreOversight WHERE ObjectName = 'vw_FinanceLedger')
    THROW 51222, 'REFUSED: the captured definition of vw_FinanceLedger is missing, so the old view cannot be rebuilt.', 1;
GO

/* ---- 1. views first, both in ONE transaction ----------------------------- */
/* Same reasoning as the cutover, mirrored: the old ledger view joins on two
   columns, so it must never be live alongside the new four-column access
   view, or the 32 cross-institution mappings double their money. */
DECLARE @accessDef nvarchar(max) =
    (SELECT Definition FROM dbo.FinanceLedgerDefs_PreOversight WHERE ObjectName = 'vw_WebAppUserAccess');
DECLARE @ledgerDef nvarchar(max) =
    (SELECT Definition FROM dbo.FinanceLedgerDefs_PreOversight WHERE ObjectName = 'vw_FinanceLedger');

/* The captured text is CREATE VIEW; ALTER lets it replace the live object. */
SET @accessDef = STUFF(@accessDef, CHARINDEX('CREATE', @accessDef), 6, 'ALTER');
SET @ledgerDef = STUFF(@ledgerDef, CHARINDEX('CREATE', @ledgerDef), 6, 'ALTER');

BEGIN TRANSACTION;
    EXEC sp_executesql @accessDef;
    EXEC sp_executesql @ledgerDef;
COMMIT TRANSACTION;
GO

PRINT 'Views restored to their pre-Oversight definitions.';
GO

/* ---- 2. the function and procs ------------------------------------------- */
DECLARE @sql nvarchar(max);

DECLARE c CURSOR LOCAL FAST_FORWARD FOR
    SELECT Definition FROM dbo.FinanceLedgerDefs_PreOversight
    WHERE ObjectName IN ('fn_FinanceLedgerSource',
                         'usp_RefreshFinanceLedgerSnapshot',
                         'usp_RefreshFinanceLedgerSnapshotAll');
OPEN c;
FETCH NEXT FROM c INTO @sql;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @sql = STUFF(@sql, CHARINDEX('CREATE', @sql), 6, 'ALTER');
    EXEC sp_executesql @sql;
    FETCH NEXT FROM c INTO @sql;
END
CLOSE c;
DEALLOCATE c;
GO

PRINT 'Function and refresh procedures restored.';
GO

/* ---- 3. the data --------------------------------------------------------- */
/* Explicit column list, NOT SELECT *: an INSERT ... SELECT * binds by
   POSITION, so a column-order difference would load money into a description
   column with no error at all. */
BEGIN TRANSACTION;

    DELETE FROM dbo.FinanceLedgerSnapshot;

    INSERT INTO dbo.FinanceLedgerSnapshot
    (
        FinancialYear, AccountNumber, AccountDescription,
        InstitutionID, ResponsibilityID, DepartmentID,
        ClusterName, InstitutionName, ResponsibilityName, DepartmentName,
        LineNumber, LineDescription, MainGroup, SubGroupA, SubGroupB,
        [Oct],[Nov],[Dec],[Jan],[Feb],[Mar],[Apr],[May],[Jun],[Jul],[Aug],[Sep],
        Q1, Q2, Q3, Q4, YTDTotal, Approved, Routing, Allocation
    )
    SELECT
        FinancialYear, AccountNumber, AccountDescription,
        InstitutionID, ResponsibilityID, DepartmentID,
        ClusterName, InstitutionName, ResponsibilityName, DepartmentName,
        LineNumber, LineDescription, MainGroup, SubGroupA, SubGroupB,
        [Oct],[Nov],[Dec],[Jan],[Feb],[Mar],[Apr],[May],[Jun],[Jul],[Aug],[Sep],
        Q1, Q2, Q3, Q4, YTDTotal, Approved, Routing, Allocation
    FROM dbo.FinanceLedgerSnapshot_PreOversight;

    /* Refresh metadata, restored by the columns the old table had. The three
       Oversight columns keep their defaults. */
    UPDATE r
       SET r.RefreshedAt     = p.RefreshedAt,
           r.RowsLoaded      = p.RowsLoaded,
           r.DurationSeconds = p.DurationSeconds,
           r.TotalAllocation = p.TotalAllocation,
           r.TotalYTD        = p.TotalYTD,
           r.Outcome         = p.Outcome,
           r.Message         = p.Message
    FROM dbo.FinanceLedgerRefresh AS r
    INNER JOIN dbo.FinanceLedgerRefresh_PreOversight AS p
            ON p.FinancialYear = r.FinancialYear;

COMMIT TRANSACTION;
GO

/* ---- 4. verify against the numbers the backup printed -------------------- */
SELECT
    'restored - compare against the backup baseline' AS label,
    FinancialYear,
    COUNT(*)                                AS accounts,
    CONVERT(decimal(19,2), SUM(Allocation)) AS total_allocation,
    CONVERT(decimal(19,2), SUM(YTDTotal))   AS total_ytd,
    CONVERT(decimal(19,2), SUM(Approved))   AS total_approved,
    CONVERT(decimal(19,2), SUM(Routing))    AS total_routing
FROM dbo.FinanceLedgerSnapshot
GROUP BY FinancialYear
ORDER BY FinancialYear DESC;
GO

/* Any row = the old two-way rule is producing duplicates, which means the
   view restore did not take. Must return NOTHING. */
SELECT TOP 10 'FAN-OUT after restore' AS alert, FinancialYear, UserName, AccountNumber, COUNT(*) AS times_matched
FROM dbo.vw_FinanceLedger
GROUP BY FinancialYear, UserName, AccountNumber
HAVING COUNT(*) > 1;
GO

PRINT 'Restore complete. Now: git revert the app commit, npm run build, php artisan cache:clear file.';
PRINT 'Keep the _PreOversight tables until the rollback itself has been accepted.';
GO
