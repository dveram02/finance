/*===========================================================================
  GL00100_Rebuild.sql
  Creates and populates [SWRHA].[dbo].[GL00100] -- the Dynamics GP Account
  Master table that the reporting SQL expects to reach over the linked
  server [GPSWRHA.SWRHA.CO.TT].

  WHY THIS EXISTS
  ---------------
  Queries such as "SQL Revised Web App.sql" (coaData CTE) read

      [GPSWRHA.SWRHA.CO.TT].[SWRHA].[dbo].[GL00100]

  and fail with:

      Msg 7314 ... The OLE DB provider "MSOLEDBSQL" for linked server
      "GPSWRHA.SWRHA.CO.TT" does not contain the table "SWRHA"."dbo"."GL00100".

  On this instance the linked server GPSWRHA.SWRHA.CO.TT is a LOOPBACK -- its
  data_source is this same SQL Server instance -- and the local [SWRHA]
  database is a partial mirror of the real GP company database: it holds
  GL40200 (243 rows) and DBA_Clusters (47 rows) but NOT GL00100.  Creating
  the table locally therefore resolves the linked-server reference with no
  change to any consuming query.

  SOURCE OF THE ACCOUNT DATA
  --------------------------
  [FinanceAutomationSystem].[dbo].[0030ADGPCOA] -- 9,463 rows -- is a
  materialised mirror of the GP chart of accounts and carries exactly the
  columns GL00100 supplies:

      AccountLineID    -> ACTINDX      (unique, 9427..18989)
      AccountSegment1  -> ACTNUMBR_1   ... AccountSegment7 -> ACTNUMBR_7
      AccountNumber    -> ACTNUMST     (unique, 27 chars, e.g.
                                        4-70100-H04-102-1026-00-000)
      AccountDescription -> ACTDESCR   (max 50 chars, matches GP char(50))

  Verified before writing this script:
    * 9,463 rows, 9,463 distinct AccountLineID, 9,463 distinct AccountNumber.
    * Segment1..7 concatenated with '-' equals AccountNumber for every row.
    * Every distinct AccountID in 0098AFinGLMaster resolves against it for
      ALL 13 fiscal years (2014-2026) -- 0 misses in every year.
    * For FY2026 the 4,450 GL-master accounts agree with it on both
      AccountNumber and AccountDescription -- 0 mismatches.

  Two smaller sources are unioned in so the master is a superset rather than
  a subset of what the reporting queries reference:
    * 0040CBudgetsAllocation  -- 355 distinct accounts (mostly payroll,
                                 70100/70500) that are budgeted but absent
                                 from 0030ADGPCOA.
    * 0040DBudgetsEncumbrance -- 2 further accounts.
    * 0098AFinGLMaster        -- ON by default (@IncludeGLMasterScan = 1).
                                 Measured to yield 0 extra accounts, but kept
                                 in so the rebuild stays correct if the COA
                                 mirror falls behind the GL load.  At 6.38M
                                 rows with no index on AccountNumber it is the
                                 one pass sensitive to server memory; set the
                                 parameter to 0 if the instance is starved.

  Accounts harvested from those three get a SYNTHESISED ACTINDX starting at
  900000 (well clear of the real 9427..18989 band) and USERDEF1 =
  'SYNTHESISED'.  Their segments are split from the account-number string by
  CHARINDEX, so the splitter is layout-independent -- it does not assume the
  1-5-3-3-4-2-3 byte offsets that other scripts in this repo hardcode.
  A synthesised ACTINDX never matches 0098AFinGLMaster.AccountID (those
  accounts have no GL activity), so it cannot corrupt the coaData join; it is
  a surrogate key only, and it is NOT stable across rebuilds.

  COLUMNS THAT ARE NOT REAL DATA
  ------------------------------
  GL00100 in GP carries posting-control columns that no local source holds.
  They are populated with GP-plausible values so the table is self-consistent,
  but they are DERIVED BY CONVENTION, not sourced -- do not report off them:

      ACCTTYPE = 1    (Posting Account) for every row.
      ACTIVE   = 1    for every row.
      PSTNGTYP        0 (Balance Sheet) when the main account segment is
                      < 40000, else 1 (Profit and Loss).
      TPCLBLNC        0 (Debit) for main account 1xxxx and 5xxxx-9xxxx,
                      1 (Credit) for 2xxxx-4xxxx.
      ACTALIAS, ACCATNUM, DECPLACS, NOTEINDX, USERDEF2 -- GP defaults.

  If the real GPSWRHA linked server is ever restored, DROP this table and the
  rebuild proc; the reference will resolve remotely again with no query change.

  SAFE TO RE-RUN.  Idempotent: creates the table only if absent, then does a
  full rebuild inside one transaction, aborting before the swap if the staged
  set is empty or contains duplicate keys.
===========================================================================*/

SET NOCOUNT ON;
GO

USE [SWRHA];
GO

/*---------------------------------------------------------------------------
  Preconditions
---------------------------------------------------------------------------*/
IF DB_ID('FinanceAutomationSystem') IS NULL
    THROW 50001, 'FinanceAutomationSystem database not found on this instance.', 1;

IF OBJECT_ID('FinanceAutomationSystem.dbo.[0030ADGPCOA]', 'U') IS NULL
    THROW 50002, 'FinanceAutomationSystem.dbo.0030ADGPCOA not found -- it is the chart-of-accounts source for GL00100.', 1;
GO

/*---------------------------------------------------------------------------
  Table
---------------------------------------------------------------------------*/
IF OBJECT_ID('dbo.GL00100', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.GL00100
    (
        ACTINDX     int             NOT NULL,
        ACTNUMBR_1  varchar(20)     NOT NULL CONSTRAINT DF_GL00100_ACTNUMBR_1 DEFAULT (''),
        ACTNUMBR_2  varchar(20)     NOT NULL CONSTRAINT DF_GL00100_ACTNUMBR_2 DEFAULT (''),
        ACTNUMBR_3  varchar(20)     NOT NULL CONSTRAINT DF_GL00100_ACTNUMBR_3 DEFAULT (''),
        ACTNUMBR_4  varchar(20)     NOT NULL CONSTRAINT DF_GL00100_ACTNUMBR_4 DEFAULT (''),
        ACTNUMBR_5  varchar(20)     NOT NULL CONSTRAINT DF_GL00100_ACTNUMBR_5 DEFAULT (''),
        ACTNUMBR_6  varchar(20)     NOT NULL CONSTRAINT DF_GL00100_ACTNUMBR_6 DEFAULT (''),
        ACTNUMBR_7  varchar(20)     NOT NULL CONSTRAINT DF_GL00100_ACTNUMBR_7 DEFAULT (''),
        ACTNUMST    varchar(75)     NOT NULL CONSTRAINT DF_GL00100_ACTNUMST  DEFAULT (''),
        ACTDESCR    varchar(50)     NOT NULL CONSTRAINT DF_GL00100_ACTDESCR  DEFAULT (''),
        ACTALIAS    varchar(20)     NOT NULL CONSTRAINT DF_GL00100_ACTALIAS  DEFAULT (''),
        ACCTTYPE    smallint        NOT NULL CONSTRAINT DF_GL00100_ACCTTYPE  DEFAULT (1),
        PSTNGTYP    smallint        NOT NULL CONSTRAINT DF_GL00100_PSTNGTYP  DEFAULT (0),
        TPCLBLNC    smallint        NOT NULL CONSTRAINT DF_GL00100_TPCLBLNC  DEFAULT (0),
        ACCATNUM    int             NOT NULL CONSTRAINT DF_GL00100_ACCATNUM  DEFAULT (0),
        ACTIVE      tinyint         NOT NULL CONSTRAINT DF_GL00100_ACTIVE    DEFAULT (1),
        DECPLACS    smallint        NOT NULL CONSTRAINT DF_GL00100_DECPLACS  DEFAULT (3),
        NOTEINDX    numeric(19, 5)  NOT NULL CONSTRAINT DF_GL00100_NOTEINDX  DEFAULT (0),
        USERDEF1    varchar(20)     NOT NULL CONSTRAINT DF_GL00100_USERDEF1  DEFAULT (''),
        USERDEF2    varchar(20)     NOT NULL CONSTRAINT DF_GL00100_USERDEF2  DEFAULT (''),
        CONSTRAINT PK_GL00100 PRIMARY KEY CLUSTERED (ACTINDX)
    );

    CREATE UNIQUE NONCLUSTERED INDEX UX_GL00100_ACTNUMST ON dbo.GL00100 (ACTNUMST);
    CREATE NONCLUSTERED INDEX IX_GL00100_Segments ON dbo.GL00100 (ACTNUMBR_3, ACTNUMBR_4, ACTNUMBR_5);

    PRINT 'Created table SWRHA.dbo.GL00100.';
END
ELSE
    PRINT 'Table SWRHA.dbo.GL00100 already exists -- contents will be rebuilt.';
GO

/*---------------------------------------------------------------------------
  Rebuild procedure
---------------------------------------------------------------------------*/
CREATE OR ALTER PROCEDURE dbo.usp_RebuildGL00100
    @IncludeGLMasterScan bit = 1   -- see step 2; set to 0 on a memory-starved instance
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @SyntheticBase int = 900000;

    ---------------------------------------------------------------------
    -- 1. Stage the real chart of accounts.
    ---------------------------------------------------------------------
    -- FinanceAutomationSystem is Latin1_General_CI_AS while SWRHA (and
    -- tempdb) are SQL_Latin1_General_CP1_CI_AS, so every string comparison
    -- that spans the two databases must be collated explicitly.  The staging
    -- table is pinned to DATABASE_DEFAULT (= SWRHA's collation, the one
    -- GL00100 itself uses) and the cross-database predicates below match it.
    CREATE TABLE #src
    (
        ACTINDX    int          NOT NULL PRIMARY KEY,
        ACTNUMBR_1 varchar(20)  COLLATE DATABASE_DEFAULT NOT NULL,
        ACTNUMBR_2 varchar(20)  COLLATE DATABASE_DEFAULT NOT NULL,
        ACTNUMBR_3 varchar(20)  COLLATE DATABASE_DEFAULT NOT NULL,
        ACTNUMBR_4 varchar(20)  COLLATE DATABASE_DEFAULT NOT NULL,
        ACTNUMBR_5 varchar(20)  COLLATE DATABASE_DEFAULT NOT NULL,
        ACTNUMBR_6 varchar(20)  COLLATE DATABASE_DEFAULT NOT NULL,
        ACTNUMBR_7 varchar(20)  COLLATE DATABASE_DEFAULT NOT NULL,
        ACTNUMST   varchar(75)  COLLATE DATABASE_DEFAULT NOT NULL,
        ACTDESCR   varchar(50)  COLLATE DATABASE_DEFAULT NOT NULL,
        USERDEF1   varchar(20)  COLLATE DATABASE_DEFAULT NOT NULL
    );

    INSERT INTO #src
        (ACTINDX, ACTNUMBR_1, ACTNUMBR_2, ACTNUMBR_3, ACTNUMBR_4,
         ACTNUMBR_5, ACTNUMBR_6, ACTNUMBR_7, ACTNUMST, ACTDESCR, USERDEF1)
    SELECT
        c.AccountLineID,
        UPPER(LTRIM(RTRIM(ISNULL(c.AccountSegment1, '')))),
        UPPER(LTRIM(RTRIM(ISNULL(c.AccountSegment2, '')))),
        UPPER(LTRIM(RTRIM(ISNULL(c.AccountSegment3, '')))),
        UPPER(LTRIM(RTRIM(ISNULL(c.AccountSegment4, '')))),
        UPPER(LTRIM(RTRIM(ISNULL(c.AccountSegment5, '')))),
        UPPER(LTRIM(RTRIM(ISNULL(c.AccountSegment6, '')))),
        UPPER(LTRIM(RTRIM(ISNULL(c.AccountSegment7, '')))),
        UPPER(LTRIM(RTRIM(c.AccountNumber))),
        LEFT(UPPER(LTRIM(RTRIM(ISNULL(c.AccountDescription, '')))), 50),
        ''
    FROM FinanceAutomationSystem.dbo.[0030ADGPCOA] AS c
    WHERE c.AccountLineID IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(c.AccountNumber)), '') IS NOT NULL;

    DECLARE @coaRows int = @@ROWCOUNT;

    -- Not declared UNIQUE: a duplicate account number must reach the sanity
    -- gate below and fail with a readable message, not an index violation.
    CREATE INDEX IX_src_ACTNUMST ON #src (ACTNUMST);

    ---------------------------------------------------------------------
    -- 2. Harvest account numbers referenced by the fact tables but absent
    --    from the chart of accounts, and synthesise master rows for them.
    --    The splitter is CHARINDEX-based, so it does not assume a fixed
    --    1-5-3-3-4-2-3 layout; rows with fewer than 6 separators are
    --    skipped rather than silently mis-parsed.
    ---------------------------------------------------------------------
    --    Each source is aggregated and staged SEPARATELY, smallest first.
    --    A single three-way UNION is NOT equivalent in cost on this instance:
    --    it runs with a very small memory-grant ceiling (workload group
    --    'default' capped at 2% -- large sorts already fail outright with
    --    "Could not get the memory grant ... exceeds the maximum configuration
    --    limit"), so a combined distinct-sort spills and does not finish.
    CREATE TABLE #ref
    (
        ACTNUMST varchar(75) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY
    );

    INSERT INTO #ref (ACTNUMST)
    SELECT x.an
    FROM (
        SELECT DISTINCT CAST(UPPER(LTRIM(RTRIM(AccountNumber))) AS varchar(75)) COLLATE DATABASE_DEFAULT AS an
        FROM FinanceAutomationSystem.dbo.[0040CBudgetsAllocation]
        WHERE NULLIF(LTRIM(RTRIM(AccountNumber)), '') IS NOT NULL
    ) AS x
    WHERE NOT EXISTS (SELECT 1 FROM #ref AS r WHERE r.ACTNUMST = x.an);

    INSERT INTO #ref (ACTNUMST)
    SELECT x.an
    FROM (
        SELECT DISTINCT CAST(UPPER(LTRIM(RTRIM(GLAccount))) AS varchar(75)) COLLATE DATABASE_DEFAULT AS an
        FROM FinanceAutomationSystem.dbo.[0040DBudgetsEncumbrance]
        WHERE NULLIF(LTRIM(RTRIM(GLAccount)), '') IS NOT NULL
    ) AS x
    WHERE NOT EXISTS (SELECT 1 FROM #ref AS r WHERE r.ACTNUMST = x.an);

    --    0098AFinGLMaster is 6.38M rows with no index on AccountNumber, so
    --    this is the expensive pass.  It yields ZERO extra accounts today --
    --    every distinct AccountID in the GL master resolves against
    --    0030ADGPCOA for all 13 fiscal years (2014-2026), and so does every
    --    distinct AccountNumber -- but it is ON by default so the rebuild
    --    stays correct if the COA mirror ever falls behind the GL load.
    --    Set @IncludeGLMasterScan = 0 only if the instance is memory-starved:
    --    at max server memory 500 MB this pass never completed, at 2048 MB the
    --    whole rebuild takes about 8 seconds.
    IF @IncludeGLMasterScan = 1
    BEGIN
        INSERT INTO #ref (ACTNUMST)
        SELECT x.an
        FROM (
            SELECT DISTINCT CAST(UPPER(LTRIM(RTRIM(AccountNumber))) AS varchar(75)) COLLATE DATABASE_DEFAULT AS an
            FROM FinanceAutomationSystem.dbo.[0098AFinGLMaster]
            WHERE NULLIF(LTRIM(RTRIM(AccountNumber)), '') IS NOT NULL
        ) AS x
        WHERE NOT EXISTS (SELECT 1 FROM #ref AS r WHERE r.ACTNUMST = x.an);
    END

    ;WITH missing AS
    (
        SELECT r.ACTNUMST
        FROM #ref AS r
        WHERE NOT EXISTS (SELECT 1 FROM #src AS s WHERE s.ACTNUMST = r.ACTNUMST)
    ),
    split AS
    (
        SELECT
            m.ACTNUMST,
            p1 = NULLIF(CHARINDEX('-', m.ACTNUMST), 0),
            p2 = NULLIF(CHARINDEX('-', m.ACTNUMST, NULLIF(CHARINDEX('-', m.ACTNUMST), 0) + 1), 0)
        FROM missing AS m
    ),
    split_all AS
    (
        SELECT
            s.ACTNUMST, s.p1, s.p2,
            p3 = NULLIF(CHARINDEX('-', s.ACTNUMST, s.p2 + 1), 0)
        FROM split AS s
        WHERE s.p1 IS NOT NULL AND s.p2 IS NOT NULL
    ),
    split4 AS
    (
        SELECT s.*, p4 = NULLIF(CHARINDEX('-', s.ACTNUMST, s.p3 + 1), 0)
        FROM split_all AS s WHERE s.p3 IS NOT NULL
    ),
    split5 AS
    (
        SELECT s.*, p5 = NULLIF(CHARINDEX('-', s.ACTNUMST, s.p4 + 1), 0)
        FROM split4 AS s WHERE s.p4 IS NOT NULL
    ),
    split6 AS
    (
        SELECT s.*, p6 = NULLIF(CHARINDEX('-', s.ACTNUMST, s.p5 + 1), 0)
        FROM split5 AS s WHERE s.p5 IS NOT NULL
    )
    INSERT INTO #src
        (ACTINDX, ACTNUMBR_1, ACTNUMBR_2, ACTNUMBR_3, ACTNUMBR_4,
         ACTNUMBR_5, ACTNUMBR_6, ACTNUMBR_7, ACTNUMST, ACTDESCR, USERDEF1)
    SELECT
        @SyntheticBase + ROW_NUMBER() OVER (ORDER BY s.ACTNUMST),
        LEFT(s.ACTNUMST, s.p1 - 1),
        SUBSTRING(s.ACTNUMST, s.p1 + 1, s.p2 - s.p1 - 1),
        SUBSTRING(s.ACTNUMST, s.p2 + 1, s.p3 - s.p2 - 1),
        SUBSTRING(s.ACTNUMST, s.p3 + 1, s.p4 - s.p3 - 1),
        SUBSTRING(s.ACTNUMST, s.p4 + 1, s.p5 - s.p4 - 1),
        SUBSTRING(s.ACTNUMST, s.p5 + 1, s.p6 - s.p5 - 1),
        SUBSTRING(s.ACTNUMST, s.p6 + 1, LEN(s.ACTNUMST) - s.p6),
        s.ACTNUMST,
        '',
        'SYNTHESISED'
    FROM split6 AS s
    WHERE s.p6 IS NOT NULL;

    DECLARE @synthRows int = @@ROWCOUNT;

    ---------------------------------------------------------------------
    -- 3. Name the synthesised rows from whatever description the GL master
    --    or the reporting-line catalogue can supply; leave 'UNDEFINED'
    --    rather than blank when nothing is known.
    ---------------------------------------------------------------------
    --    Gated on the same switch as the harvest above: without that scan the
    --    synthesised set contains only accounts the GL master does not hold,
    --    so the lookup is guaranteed to match nothing and would cost a full
    --    6.38M-row aggregate for no rows.  One aggregated pass joined to the
    --    staged set -- never a per-row lookup.
    IF @IncludeGLMasterScan = 1
       AND EXISTS (SELECT 1 FROM #src WHERE USERDEF1 = 'SYNTHESISED')
    BEGIN
        UPDATE s
           SET s.ACTDESCR = LEFT(g.AccountDescription, 50)
        FROM #src AS s
        INNER JOIN (
            SELECT CAST(UPPER(LTRIM(RTRIM(m.AccountNumber))) AS varchar(75)) COLLATE DATABASE_DEFAULT AS ACTNUMST,
                   CAST(MAX(UPPER(LTRIM(RTRIM(m.AccountDescription)))) AS varchar(50)) COLLATE DATABASE_DEFAULT AS AccountDescription
            FROM FinanceAutomationSystem.dbo.[0098AFinGLMaster] AS m
            WHERE NULLIF(LTRIM(RTRIM(m.AccountDescription)), '') IS NOT NULL
            GROUP BY UPPER(LTRIM(RTRIM(m.AccountNumber)))
        ) AS g ON g.ACTNUMST = s.ACTNUMST
        WHERE s.USERDEF1 = 'SYNTHESISED';
    END

    UPDATE #src SET ACTDESCR = 'UNDEFINED'
    WHERE USERDEF1 = 'SYNTHESISED' AND NULLIF(ACTDESCR, '') IS NULL;

    ---------------------------------------------------------------------
    -- 4. Sanity gates -- abort with the previous contents intact.
    ---------------------------------------------------------------------
    IF @coaRows = 0
        THROW 50010, 'Rebuild aborted: 0030ADGPCOA staged zero rows.', 1;

    IF EXISTS (SELECT 1 FROM #src GROUP BY ACTNUMST HAVING COUNT(*) > 1)
        THROW 50011, 'Rebuild aborted: duplicate ACTNUMST in the staged set.', 1;

    IF EXISTS (SELECT 1 FROM #src WHERE ACTINDX >= @SyntheticBase AND USERDEF1 <> 'SYNTHESISED')
        THROW 50012, 'Rebuild aborted: a real ACTINDX collides with the synthetic key band.', 1;

    ---------------------------------------------------------------------
    -- 5. Swap.
    ---------------------------------------------------------------------
    BEGIN TRANSACTION;

        DELETE FROM dbo.GL00100;

        INSERT INTO dbo.GL00100
            (ACTINDX, ACTNUMBR_1, ACTNUMBR_2, ACTNUMBR_3, ACTNUMBR_4,
             ACTNUMBR_5, ACTNUMBR_6, ACTNUMBR_7, ACTNUMST, ACTDESCR,
             ACTALIAS, ACCTTYPE, PSTNGTYP, TPCLBLNC, ACCATNUM, ACTIVE,
             DECPLACS, NOTEINDX, USERDEF1, USERDEF2)
        SELECT
            s.ACTINDX,
            s.ACTNUMBR_1, s.ACTNUMBR_2, s.ACTNUMBR_3, s.ACTNUMBR_4,
            s.ACTNUMBR_5, s.ACTNUMBR_6, s.ACTNUMBR_7,
            s.ACTNUMST,
            s.ACTDESCR,
            '',                                     -- ACTALIAS
            1,                                      -- ACCTTYPE: Posting Account
            CASE WHEN TRY_CAST(s.ACTNUMBR_2 AS int) IS NULL THEN 0
                 WHEN TRY_CAST(s.ACTNUMBR_2 AS int) < 40000 THEN 0   -- Balance Sheet
                 ELSE 1                                              -- Profit and Loss
            END,
            CASE WHEN TRY_CAST(s.ACTNUMBR_2 AS int) IS NULL THEN 0
                 WHEN TRY_CAST(s.ACTNUMBR_2 AS int) BETWEEN 20000 AND 49999 THEN 1  -- Credit
                 ELSE 0                                                             -- Debit
            END,
            0,                                      -- ACCATNUM
            1,                                      -- ACTIVE
            3,                                      -- DECPLACS
            0,                                      -- NOTEINDX
            s.USERDEF1,
            ''                                      -- USERDEF2
        FROM #src AS s;

    COMMIT TRANSACTION;

    DROP TABLE #src;
    DROP TABLE #ref;

    PRINT 'GL00100 rebuilt: ' + CAST(@coaRows AS varchar(20)) + ' chart-of-accounts rows + '
        + CAST(@synthRows AS varchar(20)) + ' synthesised rows.';
END
GO

/*---------------------------------------------------------------------------
  Build it
---------------------------------------------------------------------------*/
EXEC dbo.usp_RebuildGL00100;
GO

/*---------------------------------------------------------------------------
  Verification
---------------------------------------------------------------------------*/
SELECT 'Row counts' AS check_name,
       COUNT(*)                                                   AS total_rows,
       SUM(CASE WHEN USERDEF1 = 'SYNTHESISED' THEN 1 ELSE 0 END)  AS synthesised,
       MIN(ACTINDX)                                               AS min_actindx,
       MAX(CASE WHEN USERDEF1 = '' THEN ACTINDX END)              AS max_real_actindx
FROM SWRHA.dbo.GL00100;

-- Every GL-master account for the two live fiscal years must resolve.
SELECT 'GL master coverage FY2025-26' AS check_name,
       COUNT(*)                                            AS distinct_accounts,
       SUM(CASE WHEN a.ACTINDX IS NULL THEN 1 ELSE 0 END)  AS unresolved
FROM (
    SELECT LTRIM(RTRIM(AccountID)) AS aid
    FROM FinanceAutomationSystem.dbo.[0098AFinGLMaster]
    WHERE FinancialYear IN ('2025', '2026')
    GROUP BY LTRIM(RTRIM(AccountID))
) AS g
LEFT JOIN SWRHA.dbo.GL00100 AS a
       ON CAST(a.ACTINDX AS varchar(20)) = g.aid COLLATE SQL_Latin1_General_CP1_CI_AS;

-- The linked-server reference that was raising Msg 7314 must now resolve.
SELECT 'Linked-server read' AS check_name, COUNT(*) AS rows_visible
FROM [GPSWRHA.SWRHA.CO.TT].[SWRHA].[dbo].[GL00100];
GO
