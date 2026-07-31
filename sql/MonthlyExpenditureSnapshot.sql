/* =============================================================================
   MonthlyExpenditure snapshot  (#3 — "materialise the whole view")
   DB: FinanceAutomationSystem

   Why:
     dbo.MonthlyExpenditure is an expensive view: linked-server hops (even after
     #2 staging), CROSS APPLY account-number splitting, PARSENAME parsing and a
     fact-table aggregation, ALL recomputed on every query. Filtering by
     FinancialYear / UserName at read time does NOT reduce that cost — the heavy
     joins are year-independent and the view rebuilds from scratch each call
     (including the "distinct FinancialYear" call that drives the FY navigator).

     A view cannot be indexed/materialised here (SCHEMABINDING forbids linked
     servers, CROSS APPLY, outer joins and aggregates). So we precompute the view
     ONCE into a local, indexed table on a schedule, and turn dbo.MonthlyExpenditure
     into a thin passthrough over it. Every app query — years list, dropdown
     options, stats, paginated rows — becomes a local clustered-index seek.

   Zero application change:
     App\Models\MonthlyExpenditure still reads the view named dbo.MonthlyExpenditure.
     We rename the current heavy view to dbo.MonthlyExpenditure_Source (preserving
     its EXACT current logic, incl. any #2 repointing) and redefine
     dbo.MonthlyExpenditure as  SELECT * FROM dbo.MonthlyExpenditureSnapshot.

   Pieces:
     1. dbo.MonthlyExpenditureSnapshot          — local indexed copy of the view.
     2. dbo.MonthlyExpenditureSnapshot_Staging  — heap built each refresh (no lock
                                                  on the live table while the slow
                                                  linked-server pull runs).
     3. dbo.MonthlyExpenditureRefresh           — 1-row freshness metadata.
     4. dbo.usp_RefreshMonthlyExpenditureSnapshot — rebuild staging, atomic swap.
     5. One-time cutover: rename heavy view -> _Source, flip the public view.

   Cutover / downtime:
     Snapshot is populated BEFORE the public view is flipped, so the swap is two
     metadata operations (sub-second). If anything is mid-flight, the app already
     degrades gracefully on a SQL error (controller try/catch -> "unavailable").

   Schedule the refresh after the GL load that feeds 0098AFinGLMaster (and after
   usp_RefreshGLSegmentLookup from #2). Via SQL Agent, or Laravel's scheduler:
     $schedule->call(fn () =>
         DB::connection('FinanceAutomationSystem')
           ->statement('EXEC dbo.usp_RefreshMonthlyExpenditureSnapshot')
     )->dailyAt('05:30');

   NOTE on column types: the snapshot/staging tables are created with SELECT ...
   INTO from the live view, so their column types match the view EXACTLY (no
   guessing, no silent truncation). This intentionally differs from the explicit
   DDL style in GLSegmentLookup_staging.sql, where the schema was known up front.
   ============================================================================= */

USE [FinanceAutomationSystem];
GO

SET XACT_ABORT ON;
GO

/* -----------------------------------------------------------------------------
   1. Snapshot + staging tables (created once, from the view's own column shape)
   -------------------------------------------------------------------------- */

-- Live table the app reads through the passthrough view.
IF OBJECT_ID('dbo.MonthlyExpenditureSnapshot', 'U') IS NULL
BEGIN
    SELECT *
    INTO dbo.MonthlyExpenditureSnapshot
    FROM dbo.MonthlyExpenditure          -- still the heavy view on first run
    WHERE 1 = 0;                         -- shape only, no rows
END
GO

-- Staging heap, identical shape. Built fresh each refresh; never read by the app.
IF OBJECT_ID('dbo.MonthlyExpenditureSnapshot_Staging', 'U') IS NULL
BEGIN
    SELECT *
    INTO dbo.MonthlyExpenditureSnapshot_Staging
    FROM dbo.MonthlyExpenditureSnapshot
    WHERE 1 = 0;
END
GO

-- Clustered index matching the app's access pattern:
--   * forUser($username)                 -> WHERE UserName = ?
--   * forYear($fy) / distinct FinancialYear per user
--   * grouping/ordering starts on PeriodID
-- The finer ORDER BY (Cluster/Institution/Responsibility/Account/Line) sorts a
-- single user+FY slice, which is small, so we keep the key narrow (and well
-- under the index key-size limit). Non-unique: many rows per (user, FY, period).
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID('dbo.MonthlyExpenditureSnapshot')
      AND name = 'CIX_MonthlyExpenditureSnapshot'
)
BEGIN
    CREATE CLUSTERED INDEX CIX_MonthlyExpenditureSnapshot
        ON dbo.MonthlyExpenditureSnapshot (UserName, FinancialYear, PeriodID);
END
GO

/* -----------------------------------------------------------------------------
   2. Freshness metadata (single row)
   -------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.MonthlyExpenditureRefresh', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.MonthlyExpenditureRefresh (
        Id              tinyint      NOT NULL CONSTRAINT PK_MonthlyExpenditureRefresh PRIMARY KEY,
        RefreshedAt     datetime2(0) NULL,
        RowsLoaded      bigint       NULL,
        DurationSeconds int          NULL,
        CONSTRAINT CK_MonthlyExpenditureRefresh_OneRow CHECK (Id = 1)
    );
    INSERT INTO dbo.MonthlyExpenditureRefresh (Id) VALUES (1);
END
GO

/* -----------------------------------------------------------------------------
   3. One-time cutover: heavy view -> _Source, populate, flip public view.
      Guarded by the existence of _Source so re-running this script is a no-op
      for the cutover (the refresh proc below stays current regardless).
   -------------------------------------------------------------------------- */
IF OBJECT_ID('dbo.MonthlyExpenditure_Source', 'V') IS NULL
BEGIN
    PRINT 'Cutover: populating snapshot from the live heavy view...';

    -- (a) Populate the snapshot ONCE from the current heavy view, while the app
    --     is still served by that same view (no downtime during the slow pull).
    TRUNCATE TABLE dbo.MonthlyExpenditureSnapshot_Staging;
    INSERT INTO dbo.MonthlyExpenditureSnapshot_Staging WITH (TABLOCK)
    SELECT * FROM dbo.MonthlyExpenditure;

    TRUNCATE TABLE dbo.MonthlyExpenditureSnapshot;
    INSERT INTO dbo.MonthlyExpenditureSnapshot WITH (TABLOCK)
    SELECT * FROM dbo.MonthlyExpenditureSnapshot_Staging;

    UPDATE dbo.MonthlyExpenditureRefresh
       SET RefreshedAt = SYSDATETIME(),
           RowsLoaded  = (SELECT COUNT_BIG(*) FROM dbo.MonthlyExpenditureSnapshot)
     WHERE Id = 1;

    -- (b) Flip: preserve the heavy logic as _Source, then point the public view
    --     at the snapshot. Two metadata operations -> sub-second swap.
    EXEC sp_rename 'dbo.MonthlyExpenditure', 'MonthlyExpenditure_Source';

    PRINT 'Cutover complete. dbo.MonthlyExpenditure now reads the snapshot.';
END
ELSE
BEGIN
    PRINT 'Cutover already done (_Source exists) — skipping.';
END
GO

-- Public view the app queries. Now a thin passthrough over the indexed snapshot.
-- (Defined outside the cutover block so it is (re)created idempotently.)
CREATE OR ALTER VIEW dbo.MonthlyExpenditure
AS
    SELECT * FROM dbo.MonthlyExpenditureSnapshot;
GO

/* -----------------------------------------------------------------------------
   4. Recurring refresh proc — rebuild staging from _Source, atomic swap.
      The slow linked-server pull happens against staging (no lock on the live
      table); the swap is a short transaction so readers block only briefly and
      never see an empty/partial table.
   -------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_RefreshMonthlyExpenditureSnapshot
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @start datetime2(3) = SYSDATETIME();

    -- (1) Slow part: recompute the full view into staging. No lock on the live
    --     snapshot, so the app keeps serving fast reads throughout.
    TRUNCATE TABLE dbo.MonthlyExpenditureSnapshot_Staging;
    INSERT INTO dbo.MonthlyExpenditureSnapshot_Staging WITH (TABLOCK)
    SELECT * FROM dbo.MonthlyExpenditure_Source;

    DECLARE @rows bigint = (SELECT COUNT_BIG(*) FROM dbo.MonthlyExpenditureSnapshot_Staging);

    -- (2) Fast part: swap staging -> live under one short transaction.
    BEGIN TRY
        BEGIN TRAN;
            TRUNCATE TABLE dbo.MonthlyExpenditureSnapshot;
            INSERT INTO dbo.MonthlyExpenditureSnapshot WITH (TABLOCK)
            SELECT * FROM dbo.MonthlyExpenditureSnapshot_Staging;

            UPDATE dbo.MonthlyExpenditureRefresh
               SET RefreshedAt     = SYSDATETIME(),
                   RowsLoaded      = @rows,
                   DurationSeconds = DATEDIFF(SECOND, @start, SYSDATETIME())
             WHERE Id = 1;
        COMMIT;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK;
        THROW;   -- surface to SQL Agent / scheduler; keep the last good snapshot
    END CATCH;

    -- Free staging rows (keep the empty table for next run).
    TRUNCATE TABLE dbo.MonthlyExpenditureSnapshot_Staging;
END
GO

PRINT 'Setup complete. Schedule: EXEC dbo.usp_RefreshMonthlyExpenditureSnapshot';
GO
