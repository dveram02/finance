/* =============================================================================
   Staging for MonthlyExpenditure segment lookups  (#2 — "read GL40200 once")
   DB: FinanceAutomationSystem

   Why:
     MonthlyExpenditure reads the GPSWRHA linked server for GL40200 (segments 2/3/4)
     and DBA_Clusters. A view can't materialise those reads (no #temp / table
     variable allowed, and CTEs are re-expanded per reference), so the linked
     server is hit on every query. These segment/cluster names change rarely,
     so we stage them into LOCAL, indexed tables and refresh on a schedule.

     After staging, point the view's lookups at these tables instead of
     [GPSWRHA.SWRHA.CO.TT]...GL40200 / DBA_Clusters. Query-time cost then has
     zero linked-server hops and the joins are local index seeks.

   Pieces:
     1. dbo.GLSegmentLookup   — GL40200 segments 2 & 4 (id + description) and
                                segment 3 ids.
     2. dbo.InstitutionLookup — segment 3 pre-joined to DBA_Clusters
                                (SegmentID -> Cluster / Institution names).
     3. dbo.usp_RefreshGLSegmentLookup — one-shot refresh of both, in a tran.

   Schedule the proc via SQL Agent, or from Laravel's scheduler:
     $schedule->call(fn () =>
         DB::connection('SWRHAExpenseControl')   // or whichever hosts this DB
           ->statement('EXEC dbo.usp_RefreshGLSegmentLookup')
     )->hourly();
   ============================================================================= */

USE [FinanceAutomationSystem];
GO

-- ── 1. GL segment id/description lookup (segments 2, 3, 4) ───────────────────
IF OBJECT_ID('dbo.GLSegmentLookup', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.GLSegmentLookup (
        SegmentNumber      varchar(2)   NOT NULL,
        SegmentID          varchar(255) NOT NULL,
        SegmentDescription varchar(255) NULL,
        CONSTRAINT PK_GLSegmentLookup PRIMARY KEY CLUSTERED (SegmentNumber, SegmentID)
    );
END
GO

-- ── 2. Institution / cluster lookup (segment 3 pre-joined to DBA_Clusters) ───
IF OBJECT_ID('dbo.InstitutionLookup', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.InstitutionLookup (
        SegmentID       varchar(255) NOT NULL,
        ClusterName     varchar(255) NULL,
        InstitutionName varchar(255) NULL,
        CONSTRAINT PK_InstitutionLookup PRIMARY KEY CLUSTERED (SegmentID)
    );
END
GO

-- ── 3. Refresh proc — pulls each remote source ONCE, swaps atomically ────────
CREATE OR ALTER PROCEDURE dbo.usp_RefreshGLSegmentLookup
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    -- Pull remote data into local temp tables first (each linked-server read
    -- happens exactly once here), then swap under a short transaction so the
    -- view never sees an empty lookup.
    SELECT DISTINCT
        [SGMTNUMB] AS SegmentNumber,
        UPPER(LTRIM(RTRIM([SGMNTID])))  AS SegmentID,
        UPPER(LTRIM(RTRIM([DSCRIPTN]))) AS SegmentDescription
    INTO #seg
    FROM [GPSWRHA.SWRHA.CO.TT].[SWRHA].[dbo].[GL40200]
    WHERE [SGMTNUMB] IN ('2', '3', '4')
        AND UPPER(LTRIM(RTRIM([SGMNTID]))) <> '';

    -- segment 4 originally required a non-empty description; enforce it here.
    DELETE FROM #seg
    WHERE SegmentNumber = '4'
        AND (SegmentDescription IS NULL OR SegmentDescription = '');

    SELECT
        S.SegmentID,
        C.CLUSTER     AS ClusterName,
        C.INSTITUTION AS InstitutionName
    INTO #inst
    FROM (SELECT DISTINCT SegmentID FROM #seg WHERE SegmentNumber = '3') AS S
    LEFT JOIN [GPSWRHA.SWRHA.CO.TT].[SWRHA].[dbo].[DBA_Clusters] AS C
        ON S.SegmentID COLLATE Latin1_General_CI_AS
         = C.[INSTITUTION CODE] COLLATE Latin1_General_CI_AS;

    BEGIN TRAN;
        TRUNCATE TABLE dbo.GLSegmentLookup;
        INSERT INTO dbo.GLSegmentLookup (SegmentNumber, SegmentID, SegmentDescription)
        SELECT SegmentNumber, SegmentID, SegmentDescription FROM #seg;

        TRUNCATE TABLE dbo.InstitutionLookup;
        INSERT INTO dbo.InstitutionLookup (SegmentID, ClusterName, InstitutionName)
        SELECT SegmentID, ClusterName, InstitutionName FROM #inst;
    COMMIT;

    DROP TABLE #seg, #inst;
END
GO

-- Initial population:
EXEC dbo.usp_RefreshGLSegmentLookup;
GO
