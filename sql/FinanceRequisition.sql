/* ===========================================================================
   FinanceRequisition.sql   -   PHASE 2, the requisition-line detail data layer
   ---------------------------------------------------------------------------
   Idempotent installer. Creates, in order:

     1. dbo.FinanceRequisitionSnapshot           - the snapshot, user-agnostic
     2. dbo.FinanceRequisitionSnapshot_Staging   - build target
     3. dbo.FinanceRequisitionRefresh            - run-keyed refresh log
     4. dbo.usp_RefreshFinanceRequisition        - build + gates + swap
     5. dbo.vw_FinanceRequisitionDetail          - read surface, goods & services
        dbo.vw_FinanceRequisitionDetailUnscoped  - read surface, every account

   Design and rationale: financesqlupdatep2.md. Progress log for every phase:
   financesqlupdateprogress.md. This file is the implementation.

   THE REFERENCE QUERIES THIS IS BUILT FROM
     sql/Phase2RequisitionDetail_Approved.sql   (Status IN ('AP','PO'))
     sql/Phase2RequisitionDetail_Routing.sql    (Status IN ('RT','HD','PN'))
   They are otherwise identical, so ONE snapshot carrying Status serves both.
   The sql/source/ drafts they derive from are reference copies only - their
   two-way access join is not shipped in any form.

   Guard on the whole thing: sql/Phase2ReconciliationTest.sql, and the same
   comparison is built into the refresh proc as gate F below.

   ---------------------------------------------------------------------------
   WHY THE VIEWS ARE IN THIS FILE, WHERE PHASE 1'S ARE IN A SEPARATE CUTOVER
   ---------------------------------------------------------------------------
   sql/FinanceLedgerOversightCutover.sql exists because vw_FinanceLedger and
   vw_WebAppUserAccess had to change TOGETHER on a system that was already
   reading them: any window where the new access view met the old ledger view
   doubled money on 25% of the mappings.

   Nothing reads the Phase 2 views. They are new objects, created once, with no
   predecessor to be briefly inconsistent with. There is no window to close, so
   there is no cutover script. If a LATER change ever alters both a Phase 2 view
   and vw_WebAppUserAccess, that change needs its own transactional cutover -
   this file is not a precedent for skipping one.

   ---------------------------------------------------------------------------
   RUN ORDER
   ---------------------------------------------------------------------------
   Phase 1 must already be deployed: gate F reads dbo.FinanceLedgerSnapshot and
   the views join dbo.vw_WebAppUserAccess.

     1. this file
     2. EXEC dbo.usp_RefreshFinanceRequisition;      -- full rebuild, all years
     3. sql/FinanceRequisitionAgentJobStep.sql       -- schedule it
     4. read the verification queries at the tail of this file

   ROLLBACK: sql/FinanceRequisitionRollback.sql
   =========================================================================== */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

USE FinanceAutomationSystem;
GO


/* ===========================================================================
   1. dbo.FinanceRequisitionSnapshot
   ---------------------------------------------------------------------------
   Grain: (FinancialYear, RequisitionNumber, PONumber, LineNbr). USER-AGNOSTIC -
   UserName is joined LIVE in the read views through dbo.vw_WebAppUserAccess,
   exactly as vw_FinanceLedger does, so a permission change takes effect on the
   next request with no refresh. Do NOT denormalise UserName into this table.

   Explicit DDL, not SELECT * INTO, for the two reasons FinanceLedger.sql gives:
   SELECT * INTO would bake the source float types in permanently, and
   INSERT ... SELECT * binds by POSITION, so a column reorder in the source
   would load money into a description column with no error. Every INSERT in
   this file carries an explicit column list.

   WHAT IS STORED THAT THE REFERENCE QUERIES DO NOT PROJECT
     OrderQuantity, QtyShipped  - the two inputs to ActBalance. The reference
       queries show only the result, so "why is this line's quantity zero?"
       cannot be answered from it. The answer is almost always "fully received",
       and storing both makes that readable instead of a re-derivation.
     IsGoodsAndServices         - the reporting-line-3 scope as a STORED FLAG
       rather than a build filter, so both documented behaviours (see
       sql/Phase2ScopeVariants.md) are two views over one table at zero read
       cost, and the runtime scope join disappears entirely.

   NAMING. The read views project ActBalance AS Quantity and ActCost AS
   ExtendedCost, matching the reference queries' output contract. The table
   keeps the unambiguous names, because a column called Quantity that is not
   the ordered quantity is a trap.

   ---------------------------------------------------------------------------
   THE PASSTHROUGH TYPES ARE THE SOURCE'S OWN, READ OFF sys.columns, NOT GUESSED
   ---------------------------------------------------------------------------
   Every carried-through column below is varchar(255) COLLATE Latin1_General_CI_AS
   because that is exactly what dbo.0040DBudgetsEncumbrance declares, with two
   exceptions that are also the source's:

     ItemDescription  varchar(MAX)  - genuinely varchar(max) at source. A first
       draft of this file declared nvarchar(500) on the reasoning that "GP
       descriptions are short"; the build failed on the FIRST row over 500
       characters, and the longest measured is 668. Do not narrow it back.
     ReqDateCreated   date          - a DATE, not a datetime. There is no time
       component to lose, which is also why the fiscal-year expression below
       needs no CAST.

   varchar and not nvarchar throughout, matching the source: an nvarchar target
   forces an implicit conversion on every row of every column for no gain, and
   there is no non-Latin1 data to preserve.

   The money columns are the deliberate exception - the source declares
   Quantity, UnitCost and ExtendedCost as FLOAT, and CLAUDE.md requires
   converting to decimal BEFORE aggregating. That conversion is the point.
   =========================================================================== */
IF OBJECT_ID('dbo.FinanceRequisitionSnapshot', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.FinanceRequisitionSnapshot
    (
        FinancialYear        varchar(10)      NOT NULL,

        -- Natural grain
        RequisitionNumber    varchar(255)     COLLATE Latin1_General_CI_AS NULL,
        PONumber             varchar(255)     COLLATE Latin1_General_CI_AS NULL,
        LineNbr              int              NULL,

        -- Requisition header / line detail, carried through from the source
        OwnerID              varchar(255)     COLLATE Latin1_General_CI_AS NULL,
        [Name]               varchar(255)     COLLATE Latin1_General_CI_AS NULL,
        [Status]             varchar(255)     COLLATE Latin1_General_CI_AS NULL,
        StatusName           varchar(255)     COLLATE Latin1_General_CI_AS NULL,
        ItemID               varchar(255)     COLLATE Latin1_General_CI_AS NULL,
        ItemDescription      varchar(max)     COLLATE Latin1_General_CI_AS NULL,
        SiteID               varchar(255)     COLLATE Latin1_General_CI_AS NULL,
        SiteLocation         varchar(255)     COLLATE Latin1_General_CI_AS NULL,
        ReqDateCreated       date             NULL,
        UofM                 varchar(255)     COLLATE Latin1_General_CI_AS NULL,
        CurrencyID           varchar(255)     COLLATE Latin1_General_CI_AS NULL,
        VendorID             varchar(255)     COLLATE Latin1_General_CI_AS NULL,
        VendorName           varchar(255)     COLLATE Latin1_General_CI_AS NULL,

        -- Account and its segments. AccountNumber is the FULL GL account; the
        -- three segment columns are what the access view joins on.
        AccountNumber        varchar(255)     COLLATE Latin1_General_CI_AS NULL,
        AccountDescription   varchar(255)     COLLATE Latin1_General_CI_AS NULL,
        AccountSegment       varchar(50)      COLLATE Latin1_General_CI_AS NULL,
        InstitutionID        varchar(50)      COLLATE Latin1_General_CI_AS NULL,
        ResponsibilityID     varchar(50)      COLLATE Latin1_General_CI_AS NULL,
        DepartmentID         varchar(50)      COLLATE Latin1_General_CI_AS NULL,

        -- Labels, carried from the source rather than re-derived from the COA
        Cluster              varchar(255)     COLLATE Latin1_General_CI_AS NULL,
        Institution          varchar(255)     COLLATE Latin1_General_CI_AS NULL,
        Department           varchar(255)     COLLATE Latin1_General_CI_AS NULL,
        ResponsibilityCentre varchar(255)     COLLATE Latin1_General_CI_AS NULL,

        -- Money. decimal(19,4) throughout - the source columns are float, and
        -- CLAUDE.md requires converting BEFORE aggregating, never rounding
        -- after. See ENCUMBRANCE COST in the reference query headers.
        OrderQuantity        decimal(19,4)    NOT NULL,
        QtyShipped           decimal(19,4)    NOT NULL,
        ActBalance           decimal(19,4)    NOT NULL,
        UnitCost             decimal(19,4)    NOT NULL,
        ActCost              decimal(19,4)    NOT NULL,

        IsGoodsAndServices   bit              NOT NULL
    );

    /* Leading FinancialYear because every page query filters on it; the access
       join then seeks on the three segment columns. Mirrors
       CIX_FinanceLedgerSnapshot, which leads on the same predicate shape.
       DELIBERATELY NOT UNIQUE - see the grain note in the refresh proc. */
    CREATE CLUSTERED INDEX CIX_FinanceRequisitionSnapshot
        ON dbo.FinanceRequisitionSnapshot
           (FinancialYear, InstitutionID, ResponsibilityID, DepartmentID, AccountNumber);

    /* The reconciliation gate and any per-account drill-down group by
       (FinancialYear, AccountNumber, Status). Narrow, so it is cheap. */
    CREATE NONCLUSTERED INDEX IX_FinanceRequisitionSnapshot_Account
        ON dbo.FinanceRequisitionSnapshot (FinancialYear, AccountNumber, [Status])
        INCLUDE (ActCost, IsGoodsAndServices);
END
GO

IF OBJECT_ID('dbo.FinanceRequisitionSnapshot_Staging', 'U') IS NULL
BEGIN
    SELECT TOP (0) *
    INTO dbo.FinanceRequisitionSnapshot_Staging
    FROM dbo.FinanceRequisitionSnapshot;

    CREATE CLUSTERED INDEX CIX_FinanceRequisitionSnapshot_Staging
        ON dbo.FinanceRequisitionSnapshot_Staging
           (FinancialYear, InstitutionID, ResponsibilityID, DepartmentID, AccountNumber);

    CREATE NONCLUSTERED INDEX IX_FinanceRequisitionSnapshot_Staging_Account
        ON dbo.FinanceRequisitionSnapshot_Staging (FinancialYear, AccountNumber, [Status])
        INCLUDE (ActCost, IsGoodsAndServices);
END
GO


/* ===========================================================================
   3. dbo.FinanceRequisitionRefresh   -   RUN-KEYED, not year-keyed
   ---------------------------------------------------------------------------
   financesqlupdatep2.md left this open: "Keying it on FinancialYear the way
   the ledger log is keyed makes no sense for a full rebuild - use a single-row
   log, or a run-keyed one, and say which in the DDL."

   DECIDED: RUN-KEYED. One row per execution, RunId IDENTITY, never updated.

   Why not year-keyed: this proc rebuilds every fiscal year in one pass, so
   there is no per-year outcome to record - a build either lands whole or is
   kept out whole.

   Why not single-row: FinanceLedgerRefresh's MERGE exists to keep the LAST
   GOOD figures visible when a run aborts, and a single row would have to
   reproduce that dance. Appending gets it for free, and it also gives the
   thing neither of those shapes gives - a short history, so "this has aborted
   every night for a week" is one query rather than an inference.

   The proc trims to the most recent @KeepRuns rows so this cannot grow
   unbounded on a nightly schedule.

   READERS: `php artisan ledger:status` reads the most recent row, and asserts
   its RefreshedAt is from the SAME RUN as FinanceLedgerRefresh's. That drift
   check is the only thing that can see a step-2-only failure - see "the
   divergence window" in financesqlupdatep2.md.
   =========================================================================== */
IF OBJECT_ID('dbo.FinanceRequisitionRefresh', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.FinanceRequisitionRefresh
    (
        RunId                 int            IDENTITY(1,1) NOT NULL PRIMARY KEY,
        RefreshedAt           datetime2(0)   NOT NULL,
        RowsLoaded            int            NOT NULL,
        DurationSeconds       int            NOT NULL,
        FiscalYearsLoaded     int            NOT NULL,
        AccountsLoaded        int            NOT NULL,

        -- Reconciliation totals the gate compares, kept so a drift can be read
        -- off the log without re-running anything.
        TotalApproved         decimal(19,4)  NOT NULL,   -- AP/PO, goods & services
        TotalRouting          decimal(19,4)  NOT NULL,   -- RT/HD/PN, goods & services
        ReconAccountsCompared int            NOT NULL,
        ReconMismatches       int            NOT NULL,   -- against FRESH ledger years
        ReconStaleYearDrift   int            NOT NULL,   -- against STALE ledger years, reported only

        -- Recorded, not gated. See the notes on each in the proc.
        DuplicateGrainRows    int            NOT NULL,
        UnparsedSegmentRows   int            NOT NULL,

        Outcome               varchar(20)    NOT NULL,   -- OK | ABORTED
        [Message]             nvarchar(2000) NULL
    );

    CREATE NONCLUSTERED INDEX IX_FinanceRequisitionRefresh_RefreshedAt
        ON dbo.FinanceRequisitionRefresh (RefreshedAt DESC) INCLUDE (Outcome);
END
GO


/* ===========================================================================
   4. dbo.usp_RefreshFinanceRequisition
   ---------------------------------------------------------------------------
   FULL REBUILD, EVERY FISCAL YEAR, EVERY RUN. There is no @Year parameter and
   no day-of-month branch, and that is a measured decision rather than a
   simplification:

     * the whole history is ~106,400 rows across 15 fiscal years (measured
       2026-08-26 on 0040DBudgetsEncumbrance, statuses AP/PO/RT/HD/PN);
     * the dominant cost is  GROUP BY PONumber, CONVERT(int, POLineID)  over
       the 250,897-row shipment table, and that is paid ONCE no matter how many
       years are built. Building one year would cost very nearly the same as
       building fifteen.

   Phase 1 branches on day-of-month because a per-FY ledger build costs minutes.
   Nothing here does, so incremental logic would be complexity bought with
   nothing.

   NOTE FY2022 and FY2023 have NO ROWS AT ALL in the source. That is source
   data, not a filter bug - which is why the zero-row gate below is per-BUILD
   and never per-year. A per-year floor would abort forever.

   GATE ORDER, and what @Force does and does not reach:

     A  source validity           THROW, never bypassed - correctness
     B  build into staging
     C  measure
     D  zero-row / floor          abort, never bypassed
     E  movement vs last good      abort, BYPASSED by @Force
     F  reconciliation vs Phase 1  abort, never bypassed - this is the whole
                                   justification for the phase
     G  swap
     H  log

   @Force exists for a genuine large movement - a new fiscal year opening, a
   bulk re-raise. It never reaches a correctness gate.
   =========================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_RefreshFinanceRequisition
    @Force                  bit            = 0,
    @MinRows                int            = 1,
    @MaxDropPercent         decimal(5,2)   = 10.00,   -- row-count fall vs last good run
    @MaxMovePercent         decimal(5,2)   = 25.00,   -- money movement vs last good run
    @ReconToleranceTTD      decimal(19,4)  = 0.05,    -- per-account rounding tolerance
    @ReconMaxLedgerAgeHours int            = 36,      -- see gate F
    @KeepRuns               int            = 200
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @startedAt datetime2(0) = SYSDATETIME();
    DECLARE @rows int, @years int, @accounts int;
    DECLARE @approved decimal(19,4), @routing decimal(19,4);
    DECLARE @dupGrain int, @unparsed int;
    DECLARE @reconCompared int = 0, @reconMismatch int = 0, @reconStale int = 0;
    DECLARE @prevRows int, @prevApproved decimal(19,4), @prevRouting decimal(19,4);
    DECLARE @abort nvarchar(2000) = NULL;
    DECLARE @badRows int, @ambiguous int, @missingCols nvarchar(1000);

    /* ---- A1. SOURCE SHAPE --------------------------------------------------
       Every column this proc reads by name, checked in one pass. Without this
       a renamed source column surfaces as "Invalid column name" from inside a
       200-line INSERT, hours later, in a job history nobody is reading. */
    SELECT @missingCols = STRING_AGG(c.col, ', ')
    FROM (VALUES
        ('RequisitionNumber'),('PONumber'),('LineNbr'),('OwnerID'),('Name'),('Status'),
        ('StatusName'),('ItemID'),('ItemDescription'),('SiteID'),('SiteLocation'),
        ('GLAccount'),('AccountDescription'),('ReqDateCreated'),('UofM'),('CurrencyID'),
        ('VendorID'),('VendorName'),('Cluster'),('Institution'),('Department'),
        ('ResponsibilityCentre'),('Quantity'),('UnitCost')
    ) AS c(col)
    WHERE NOT EXISTS (
        SELECT 1 FROM sys.columns
        WHERE object_id = OBJECT_ID('[FinanceAutomationSystem].[dbo].[0040DBudgetsEncumbrance]')
          AND name = c.col COLLATE Latin1_General_CI_AS
    );

    IF @missingCols IS NOT NULL
    BEGIN
        DECLARE @mc nvarchar(1200) = N'Refresh aborted: 0040DBudgetsEncumbrance is missing column(s) '
            + @missingCols + N'. The source schema has changed; re-read sql/FinanceRequisition.sql '
            + N'against it before rebuilding.';
        THROW 51100, @mc, 1;
    END

    IF OBJECT_ID('dbo.vw_WebAppUserAccess', 'V') IS NULL
        THROW 51101, 'Refresh aborted: dbo.vw_WebAppUserAccess does not exist. Phase 1 must be deployed first - the Phase 2 read views join it live.', 1;

    /* ---- A2. SHIPMENT CONVERSION GUARD -------------------------------------
       Identical in intent to Phase 1's gate 4d, and identical in reason: the
       build uses CONVERT (not TRY_CONVERT) on the varchar shipment columns
       DELIBERATELY, so bad data cannot be silently discarded into an
       understated shipment and an overstated commitment. This gate catches it
       first and gives a usable message instead of a raw conversion error.

       It also settles an open item that financesqlupdatep2.md carried from the
       drafts: "the int = varchar join A.LineNbr = B.POLineID ... a live view
       has no pre-pass, so a non-numeric POLineID errors." Snapshot-backed, it
       DOES have a pre-pass, and this is it.

       Whole-table, not per-year: this proc builds every year. */
    SELECT @badRows = COUNT(*)
    FROM [FinanceAutomationSystem].[dbo].[0098FPOShipmentDetails]
    WHERE TRY_CONVERT(int, POLineID) IS NULL
       OR TRY_CONVERT(decimal(19,4), QTYShipped) IS NULL;

    IF @badRows > 0
    BEGIN
        DECLARE @bad nvarchar(400) = N'Refresh aborted: '
            + CONVERT(nvarchar(20), @badRows)
            + N' row(s) in 0098FPOShipmentDetails have a non-numeric POLineID or QTYShipped. '
            + N'Encumbrance cannot be netted safely. Fix the source rows; do not skip them.';
        THROW 51102, @bad, 1;
    END

    /* ---- A3. SHIPMENT KEY AMBIGUITY ----------------------------------------
       A duplicated (PONumber, POLineID) is two DISTINCT GP lines colliding on
       an insufficient key - POLNENUM tells them apart - so summing across them
       is wrong. 65 such keys exist and none currently intersects an open
       requisition. Phase 1 checks this for the one year it is building; this
       checks it across every year, because that is what is being built. */
    SELECT @ambiguous = COUNT(*)
    FROM (
        SELECT PONumber, TRY_CONVERT(int, POLineID) AS POLineID
        FROM [FinanceAutomationSystem].[dbo].[0098FPOShipmentDetails]
        GROUP BY PONumber, TRY_CONVERT(int, POLineID)
        HAVING COUNT(*) > 1
    ) AS dup
    INNER JOIN [FinanceAutomationSystem].[dbo].[0040DBudgetsEncumbrance] AS e
            ON e.PONumber = dup.PONumber
           AND e.LineNbr  = dup.POLineID
    WHERE e.[Status] IN ('AP','PO','RT','HD','PN');

    IF @ambiguous > 0
    BEGIN
        DECLARE @amb nvarchar(600) = N'Refresh aborted: '
            + CONVERT(nvarchar(20), @ambiguous)
            + N' open encumbrance line(s) match a duplicated (PONumber, POLineID) shipment key. '
            + N'Those are different GP lines, so summing their shipments would corrupt the commitment. '
            + N'Establish the correct unique key (likely including POLNENUM) with finance/GP and update '
            + N'BOTH this proc and dbo.fn_FinanceLedgerSource - Phase 1 carries the same join.';
        THROW 51103, @amb, 1;
    END

    /* ---- B. BUILD ----------------------------------------------------------
       Two temp tables materialised ONCE, which is the entire performance
       argument for this phase:

         #Shipments  - the ~47s aggregate. Measured 2026-08-26, this is the
                       whole cost of the reference query; everything else is
                       noise. Paid once per refresh here instead of once per
                       page load.
         #GoodsSvc   - the 41-code reporting-line-3 list. 87ms, but hoisting it
                       keeps the flag computation a single hash join.          */
    IF OBJECT_ID('tempdb..#Shipments') IS NOT NULL DROP TABLE #Shipments;
    IF OBJECT_ID('tempdb..#GoodsSvc')  IS NOT NULL DROP TABLE #GoodsSvc;

    SELECT PONumber,
           CONVERT(int, POLineID) AS POLineID,
           SUM(CONVERT(decimal(19,4), QTYShipped)) AS QtyShipped
    INTO #Shipments
    FROM [FinanceAutomationSystem].[dbo].[0098FPOShipmentDetails]
    GROUP BY PONumber, CONVERT(int, POLineID);

    CREATE UNIQUE CLUSTERED INDEX CIX_Shipments ON #Shipments (PONumber, POLineID);

    /* The reporting-line-3 (goods and services) account list. Same chain as
       Phase 1's varianceLines and the reference queries': report LineID 3 ->
       report lines -> report accounts. DISTINCT is a guard, not a fix - the
       list cannot currently fan out (41 rows / 41 distinct accounts) - but a
       join to a non-distinct list WOULD duplicate detail rows. */
    /* CAST(... AS varchar(50)) COLLATE ... is Phase 1's varianceLines
       expression VERBATIM, and it is not decoration: 0030ACCOAReportAccounts
       declares AccountNumber as an INT. Any other conversion here - or relying
       on an implicit one - risks the two phases matching the same account by
       different rules, which is precisely what gate F would then report as a
       money defect. */
    SELECT DISTINCT
           CAST(C.AccountNumber AS varchar(50)) COLLATE Latin1_General_CI_AS AS AccountSegment
    INTO #GoodsSvc
    FROM [FinanceAutomationSystem].[dbo].[0030AACOAReports] AS A
    INNER JOIN [FinanceAutomationSystem].[dbo].[0030ABCOAReportlines] AS B
            ON A.LineID = B.ReportID
           AND B.LineDescription NOT LIKE '%TOTAL%'
    INNER JOIN [FinanceAutomationSystem].[dbo].[0030ACCOAReportAccounts] AS C
            ON B.LineNumber = C.ReportingLineID
    WHERE A.LineID = 3
      AND C.AccountNumber IS NOT NULL;

    CREATE UNIQUE CLUSTERED INDEX CIX_GoodsSvc ON #GoodsSvc (AccountSegment);

    DELETE FROM dbo.FinanceRequisitionSnapshot_Staging;

    INSERT INTO dbo.FinanceRequisitionSnapshot_Staging
    (
        FinancialYear, RequisitionNumber, PONumber, LineNbr,
        OwnerID, [Name], [Status], StatusName, ItemID, ItemDescription,
        SiteID, SiteLocation, ReqDateCreated, UofM, CurrencyID, VendorID, VendorName,
        AccountNumber, AccountDescription, AccountSegment,
        InstitutionID, ResponsibilityID, DepartmentID,
        Cluster, Institution, Department, ResponsibilityCentre,
        OrderQuantity, QtyShipped, ActBalance, UnitCost, ActCost,
        IsGoodsAndServices
    )
    SELECT
        /* A fiscal year runs 1 Oct -> 30 Sep and is named for the year it ENDS
           in. Same expression as the reference queries, minus their
           CAST(ReqDateCreated AS DATE) - the column IS a date, so that cast
           was always a no-op. Phase 1 uses sargable DATE bounds instead
           because it filters to one year; there is nothing to push down here,
           and the two forms are equivalent for every non-null date. */
        CONVERT(varchar(10),
            CASE WHEN MONTH(e.ReqDateCreated) >= 10
                 THEN YEAR(e.ReqDateCreated) + 1
                 ELSE YEAR(e.ReqDateCreated) END)                         AS FinancialYear,
        e.RequisitionNumber,
        e.PONumber,
        e.LineNbr,
        e.OwnerID,
        e.[Name],
        e.[Status],
        e.StatusName,
        e.ItemID,
        e.ItemDescription,
        e.SiteID,
        e.SiteLocation,
        e.ReqDateCreated,
        e.UofM,
        e.CurrencyID,
        e.VendorID,
        e.VendorName,

        /* UPPER/TRIM to match Phase 1's encumbranceData exactly. The
           reconciliation gate joins these two populations on AccountNumber;
           a casing or padding difference on either side would read as a
           mismatch and abort every build. */
        UPPER(LTRIM(RTRIM(e.GLAccount))) COLLATE Latin1_General_CI_AS       AS AccountNumber,
        e.AccountDescription,
        seg.AccountSeg,
        seg.InstitutionSeg,
        seg.ResponsibilitySeg,
        seg.DepartmentSeg,

        e.Cluster,
        e.Institution,
        e.Department,
        e.ResponsibilityCentre,

        CONVERT(decimal(19,4), ISNULL(e.Quantity, 0))                       AS OrderQuantity,
        ISNULL(s.QtyShipped, 0)                                             AS QtyShipped,
        b.ActBalance,
        CONVERT(decimal(19,4), ISNULL(e.UnitCost, 0))                       AS UnitCost,
        a.ActCost,

        CASE WHEN gs.AccountSegment IS NULL THEN 0 ELSE 1 END               AS IsGoodsAndServices
    FROM [FinanceAutomationSystem].[dbo].[0040DBudgetsEncumbrance] AS e

    /* Pre-aggregated, so this join CANNOT fan out. This is the correction the
       drafts were missing, and one of the three that broke reconciliation -
       see ENCUMBRANCE COST in the reference query headers. Gate A3 above
       guarantees no open line meets a duplicated key. */
    LEFT JOIN #Shipments AS s
           ON s.PONumber = e.PONumber
          AND s.POLineID = e.LineNbr

    /* SEGMENT PARSING - and this is a DELIBERATE DEPARTURE from the reference
       queries, which is worth reading before "restoring" them.

       The reference queries inherit the drafts' FIXED substring offsets:
       substring(GLAccount, 3, 5), (9, 3), (13, 3), (17, 4). Phase 1 replaced
       exactly that with the delimiter-driven splitter below, because account
       numbers are NOT all the same width - measured 2026-08-25, 4 accounts are
       26 characters against 6,776 at 27, so fixed offsets silently mis-parse
       them into segments that match no access grant and no COA row.

       Phase 2 must use the SAME derivation as Phase 1, for a reason stronger
       than tidiness: gate F compares the two populations per account, and the
       access views join on these segments. Two different splitters would make
       the reconciliation gate compare rows that Phase 1 scoped one way and
       Phase 2 scoped another, and the drift would look like a money defect.

       This did not change the measured KCHARLES1 / FY2026 figures - no
       26-character account carried an open line in that scope - so the
       reconciliation evidence in financesqlupdatep2.md still stands. It closes
       a latent defect rather than fixing an observed one.

           {prefix}-{account}-{institution}-{responsibility}-{department}-{..}-{..}
           e.g.  4 - 80400 - H01 - 107 - 1157 - 00 - 000                        */
    CROSS APPLY (SELECT UPPER(LTRIM(RTRIM(e.GLAccount))) COLLATE Latin1_General_CI_AS AS Acct) AS n
    CROSS APPLY (SELECT NULLIF(CHARINDEX('-', n.Acct), 0) AS d1) AS p1
    CROSS APPLY (SELECT NULLIF(CHARINDEX('-', n.Acct, p1.d1 + 1), 0) AS d2) AS p2
    CROSS APPLY (SELECT NULLIF(CHARINDEX('-', n.Acct, p2.d2 + 1), 0) AS d3) AS p3
    CROSS APPLY (SELECT NULLIF(CHARINDEX('-', n.Acct, p3.d3 + 1), 0) AS d4) AS p4
    CROSS APPLY (SELECT NULLIF(CHARINDEX('-', n.Acct, p4.d4 + 1), 0) AS d5) AS p5
    CROSS APPLY (
        SELECT
            CONVERT(varchar(50), LTRIM(RTRIM(SUBSTRING(n.Acct, p1.d1 + 1, p2.d2 - p1.d1 - 1)))) AS AccountSeg,
            CONVERT(varchar(50), LTRIM(RTRIM(SUBSTRING(n.Acct, p2.d2 + 1, p3.d3 - p2.d2 - 1)))) AS InstitutionSeg,
            CONVERT(varchar(50), LTRIM(RTRIM(SUBSTRING(n.Acct, p3.d3 + 1, p4.d4 - p3.d3 - 1)))) AS ResponsibilitySeg,
            CONVERT(varchar(50), LTRIM(RTRIM(SUBSTRING(n.Acct, p4.d4 + 1, p5.d5 - p4.d4 - 1)))) AS DepartmentSeg
    ) AS seg

    /* ActBalance / ActCost - the Phase 1 definition VERBATIM. All three of the
       corrections it carries are load-bearing and were each measured to break
       reconciliation when absent:
         1. FLOORED AT ZERO. An over-shipped line is not a negative commitment.
            4,365 over-shipped lines carry TTD 118,656,213.96 that would
            otherwise net off other lines' genuine commitments. One account
            read -5,945,460.79 in detail against +1,513,488.86 in the summary.
         2. SHIPMENTS PRE-AGGREGATED - the join above.
         3. decimal(19,4) BEFORE multiplying, not ROUND() after.
       Do not simplify this back. */
    CROSS APPLY (
        SELECT CASE
            WHEN CONVERT(decimal(19,4), ISNULL(e.Quantity, 0)) - ISNULL(s.QtyShipped, 0) > 0
            THEN CONVERT(decimal(19,4), ISNULL(e.Quantity, 0)) - ISNULL(s.QtyShipped, 0)
            ELSE CONVERT(decimal(19,4), 0)
        END AS ActBalance
    ) AS b
    /* The explicit CONVERT matters: decimal(19,4) * decimal(19,4) infers
       decimal(38,8), and letting that propagate would silently widen the
       column's effective type. */
    CROSS APPLY (
        SELECT CONVERT(decimal(19,4),
                   b.ActBalance * CONVERT(decimal(19,4), ISNULL(e.UnitCost, 0))) AS ActCost
    ) AS a

    /* LEFT, not INNER. Scope is a STORED FLAG, not a build filter - that is
       what makes both documented behaviours two free views over one table.
       An INNER JOIN here would delete the unscoped variant's data. */
    LEFT JOIN #GoodsSvc AS gs ON gs.AccountSegment = seg.AccountSeg

    WHERE e.[Status] IN ('AP','PO','RT','HD','PN')
      AND e.GLAccount IS NOT NULL
      AND e.ReqDateCreated IS NOT NULL;

    /* ---- C. MEASURE -------------------------------------------------------- */
    SELECT
        @rows     = COUNT(*),
        @years    = COUNT(DISTINCT FinancialYear),
        @accounts = COUNT(DISTINCT AccountNumber),
        @approved = ISNULL(SUM(CASE WHEN IsGoodsAndServices = 1 AND [Status] IN ('AP','PO')      THEN ActCost ELSE 0 END), 0),
        @routing  = ISNULL(SUM(CASE WHEN IsGoodsAndServices = 1 AND [Status] IN ('RT','HD','PN') THEN ActCost ELSE 0 END), 0),
        /* Recorded, NOT gated. A NULL segment means the account number carries
           fewer than five delimiters, so the row can never match an access
           grant and is invisible to every user. That is bad, but it is also
           exactly what Phase 1 already does with the same account - both sides
           hide it consistently, so gate F still ties. Aborting here would
           abort Phase 2 on a condition Phase 1 tolerates, which is the wrong
           asymmetry. Surfaced by `php artisan ledger:status` instead. */
        @unparsed = SUM(CASE WHEN InstitutionID IS NULL OR ResponsibilityID IS NULL
                               OR DepartmentID IS NULL THEN 1 ELSE 0 END)
    FROM dbo.FinanceRequisitionSnapshot_Staging;

    /* Also recorded, not gated. A duplicated natural grain does NOT multiply
       money here - rows are copied 1:1 from the source with no fan-out left
       to introduce one, and gate F would catch it if it did. It matters to
       Phase 3, which needs a stable row key, so it is measured and reported
       rather than assumed away. */
    SELECT @dupGrain = ISNULL(SUM(n - 1), 0)
    FROM (
        SELECT COUNT(*) AS n
        FROM dbo.FinanceRequisitionSnapshot_Staging
        GROUP BY FinancialYear, RequisitionNumber, PONumber, LineNbr
        HAVING COUNT(*) > 1
    ) AS d;

    SELECT TOP (1)
        @prevRows = RowsLoaded, @prevApproved = TotalApproved, @prevRouting = TotalRouting
    FROM dbo.FinanceRequisitionRefresh
    WHERE Outcome = 'OK'
    ORDER BY RunId DESC;

    /* ---- D. ZERO-ROW / FLOOR  (never bypassed) ------------------------------
       PER BUILD, not per year - FY2022 and FY2023 have no source rows at all,
       and a per-year floor would abort forever on legitimate source data. */
    IF @rows = 0
        SET @abort = N'Staging is empty - the source returned no open encumbrance rows at all.';
    ELSE IF @rows < @MinRows
        SET @abort = N'Staging row count ' + CONVERT(nvarchar(20), @rows)
                   + N' is below the floor of ' + CONVERT(nvarchar(20), @MinRows) + N'.';

    /* ---- E. MOVEMENT  (bypassed by @Force) ---------------------------------- */
    IF @abort IS NULL AND @Force = 0 AND @prevRows IS NOT NULL AND @prevRows > 0
    BEGIN
        IF (100.0 * (@prevRows - @rows) / @prevRows) > @MaxDropPercent
            SET @abort = N'Row count fell from ' + CONVERT(nvarchar(20), @prevRows)
                       + N' to ' + CONVERT(nvarchar(20), @rows) + N'.';
        ELSE IF @prevApproved <> 0 AND ABS(100.0 * (@approved - @prevApproved) / @prevApproved) > @MaxMovePercent
            SET @abort = N'Total Approved moved from ' + CONVERT(nvarchar(40), @prevApproved)
                       + N' to ' + CONVERT(nvarchar(40), @approved) + N'.';
        ELSE IF @prevRouting <> 0 AND ABS(100.0 * (@routing - @prevRouting) / @prevRouting) > @MaxMovePercent
            SET @abort = N'Total Routing moved from ' + CONVERT(nvarchar(40), @prevRouting)
                       + N' to ' + CONVERT(nvarchar(40), @routing) + N'.';
    END

    /* ---- F. RECONCILIATION AGAINST PHASE 1  (never bypassed) ----------------
       THE REASON THIS PHASE IS SNAPSHOT-BACKED AT ALL.

       Phase 2's whole justification for carrying the goods-and-services scope
       is that detail must agree with the summary it drills into. On a live view
       that agreement is asserted by running sql/Phase2ReconciliationTest.sql by
       hand and hoping nobody changes anything. Here it is a BUILD-TIME GATE: if
       per-account detail totals do not tie to FinanceLedgerSnapshot's Approved
       and Routing, the build aborts and the previous snapshot stands.

       USER-AGNOSTIC on both sides. The reconciliation test compares as one
       user because it runs read-only against live views; this compares the two
       SNAPSHOTS, which is the stronger statement - it ties for every account,
       not just the ones one user can see.

       ---------------------------------------------------------------------
       WHY IT ONLY GATES ON *FRESH* LEDGER YEARS - the operational trap
       ---------------------------------------------------------------------
       The Agent job refreshes the ledger for the current + prior FY on most
       nights and every FY only on the 1st. Phase 2 rebuilds ALL years every
       run. So if a CLOSED year's encumbrance changes in the source, Phase 2
       picks it up tonight and Phase 1 does not until the 1st - and a gate that
       compared every year would then abort every single night until the
       monthly full rebuild caught up. The detail would freeze for weeks
       because of a correct disagreement.

       So: years whose ledger snapshot was refreshed within
       @ReconMaxLedgerAgeHours are GATED. Older years are still compared, but
       the result is RECORDED (ReconStaleYearDrift) rather than aborted, and it
       is a genuine signal - a non-zero value means the next full ledger
       rebuild will move those years.

       This is not a loophole. The years that matter - the ones users read -
       are refreshed nightly by step 1 immediately before step 2 runs, so they
       are always inside the window and always gated.                          */
    IF @abort IS NULL
    BEGIN
        IF OBJECT_ID('dbo.FinanceLedgerSnapshot', 'U') IS NULL
            SET @abort = N'dbo.FinanceLedgerSnapshot does not exist. Phase 1 must be deployed before Phase 2 can reconcile against it.';
        ELSE IF NOT EXISTS (SELECT 1 FROM dbo.FinanceLedgerSnapshot)
            SET @abort = N'dbo.FinanceLedgerSnapshot is empty. Rebuild the ledger before refreshing the requisition detail.';
    END

    IF @abort IS NULL
    BEGIN
        DECLARE @recon TABLE (
            FinancialYear varchar(10),
            AccountNumber varchar(255) COLLATE Latin1_General_CI_AS,
            LedgerFresh   bit,
            DiffApproved  decimal(19,4),
            DiffRouting   decimal(19,4)
        );

        INSERT INTO @recon (FinancialYear, AccountNumber, LedgerFresh, DiffApproved, DiffRouting)
        SELECT
            COALESCE(p2.FinancialYear, p1.FinancialYear),
            COALESCE(p2.AccountNumber, p1.AccountNumber),
            fy.IsFresh,
            ISNULL(p2.Approved, 0) - ISNULL(p1.Approved, 0),
            ISNULL(p2.Routing,  0) - ISNULL(p1.Routing,  0)
        FROM (
            SELECT FinancialYear, AccountNumber,
                   SUM(CASE WHEN [Status] IN ('AP','PO')      THEN ActCost ELSE 0 END) AS Approved,
                   SUM(CASE WHEN [Status] IN ('RT','HD','PN') THEN ActCost ELSE 0 END) AS Routing
            FROM dbo.FinanceRequisitionSnapshot_Staging
            WHERE IsGoodsAndServices = 1
            GROUP BY FinancialYear, AccountNumber
        ) AS p2
        FULL OUTER JOIN (
            SELECT FinancialYear, AccountNumber, Approved, Routing
            FROM dbo.FinanceLedgerSnapshot
        ) AS p1
            ON  p1.FinancialYear = p2.FinancialYear
            AND p1.AccountNumber = p2.AccountNumber
        /* A fiscal year the LEDGER has never built cannot be compared at all -
           there is nothing on the other side. Those are excluded rather than
           counted as mismatches: the ledger holds FY2025+ for allocation and
           FY2014+ for GL, and the two rails legitimately differ in length. */
        INNER JOIN (
            SELECT r.FinancialYear,
                   CASE WHEN r.RefreshedAt >= DATEADD(hour, -@ReconMaxLedgerAgeHours, SYSDATETIME())
                        THEN 1 ELSE 0 END AS IsFresh
            FROM dbo.FinanceLedgerRefresh AS r
            WHERE r.Outcome = 'OK'
        ) AS fy
            ON fy.FinancialYear = COALESCE(p2.FinancialYear, p1.FinancialYear);

        SELECT
            @reconCompared = COUNT(*),
            @reconMismatch = SUM(CASE WHEN LedgerFresh = 1
                                       AND (ABS(DiffApproved) > @ReconToleranceTTD
                                         OR ABS(DiffRouting)  > @ReconToleranceTTD) THEN 1 ELSE 0 END),
            @reconStale    = SUM(CASE WHEN LedgerFresh = 0
                                       AND (ABS(DiffApproved) > @ReconToleranceTTD
                                         OR ABS(DiffRouting)  > @ReconToleranceTTD) THEN 1 ELSE 0 END)
        FROM @recon;

        IF @reconMismatch > 0
        BEGIN
            DECLARE @worst nvarchar(300);
            SELECT TOP (1) @worst = N'worst: FY' + FinancialYear + N' ' + AccountNumber
                         + N' Approved drift ' + CONVERT(nvarchar(40), DiffApproved)
                         + N', Routing drift ' + CONVERT(nvarchar(40), DiffRouting)
            FROM @recon
            WHERE LedgerFresh = 1
            ORDER BY ABS(DiffApproved) + ABS(DiffRouting) DESC;

            SET @abort = N'RECONCILIATION FAILED: ' + CONVERT(nvarchar(20), @reconMismatch)
                       + N' account(s) do not tie to dbo.FinanceLedgerSnapshot Approved/Routing ('
                       + @worst + N'). The detail would disagree with the summary it drills into. '
                       + N'Diagnose with sql/Phase2ReconciliationTest.sql before forcing anything - '
                       + N'@Force does NOT bypass this gate, deliberately.';
        END
    END

    /* ---- abort path -------------------------------------------------------- */
    IF @abort IS NOT NULL
    BEGIN
        DELETE FROM dbo.FinanceRequisitionSnapshot_Staging;

        /* Appended as its own row. The last good run's figures are untouched -
           that is the point of a run-keyed log. */
        INSERT INTO dbo.FinanceRequisitionRefresh
            (RefreshedAt, RowsLoaded, DurationSeconds, FiscalYearsLoaded, AccountsLoaded,
             TotalApproved, TotalRouting, ReconAccountsCompared, ReconMismatches, ReconStaleYearDrift,
             DuplicateGrainRows, UnparsedSegmentRows, Outcome, [Message])
        VALUES
            (SYSDATETIME(), 0, DATEDIFF(second, @startedAt, SYSDATETIME()), 0, 0,
             0, 0, ISNULL(@reconCompared, 0), ISNULL(@reconMismatch, 0), ISNULL(@reconStale, 0),
             ISNULL(@dupGrain, 0), ISNULL(@unparsed, 0), 'ABORTED', @abort);

        DECLARE @msg nvarchar(2000) = N'Requisition refresh aborted: ' + @abort
            + N' Previous snapshot retained.';
        THROW 51104, @msg, 1;
    END

    /* ---- G. SWAP -----------------------------------------------------------
       Full replace, in one short transaction. ~106k rows, so this is seconds -
       there is no case for a per-year swap here the way Phase 1 needs one.

       DELETE rather than TRUNCATE deliberately: the Agent account is granted
       INSERT and DELETE on these tables (see sql/FinanceRequisitionAgentJobStep.sql),
       and TRUNCATE would require ALTER. Widening that grant to save a second on
       a nightly job is not a trade worth making. */
    BEGIN TRANSACTION;

        DELETE FROM dbo.FinanceRequisitionSnapshot;

        INSERT INTO dbo.FinanceRequisitionSnapshot
        (
            FinancialYear, RequisitionNumber, PONumber, LineNbr,
            OwnerID, [Name], [Status], StatusName, ItemID, ItemDescription,
            SiteID, SiteLocation, ReqDateCreated, UofM, CurrencyID, VendorID, VendorName,
            AccountNumber, AccountDescription, AccountSegment,
            InstitutionID, ResponsibilityID, DepartmentID,
            Cluster, Institution, Department, ResponsibilityCentre,
            OrderQuantity, QtyShipped, ActBalance, UnitCost, ActCost,
            IsGoodsAndServices
        )
        SELECT
            FinancialYear, RequisitionNumber, PONumber, LineNbr,
            OwnerID, [Name], [Status], StatusName, ItemID, ItemDescription,
            SiteID, SiteLocation, ReqDateCreated, UofM, CurrencyID, VendorID, VendorName,
            AccountNumber, AccountDescription, AccountSegment,
            InstitutionID, ResponsibilityID, DepartmentID,
            Cluster, Institution, Department, ResponsibilityCentre,
            OrderQuantity, QtyShipped, ActBalance, UnitCost, ActCost,
            IsGoodsAndServices
        FROM dbo.FinanceRequisitionSnapshot_Staging;

        /* ---- H. LOG -------------------------------------------------------- */
        INSERT INTO dbo.FinanceRequisitionRefresh
            (RefreshedAt, RowsLoaded, DurationSeconds, FiscalYearsLoaded, AccountsLoaded,
             TotalApproved, TotalRouting, ReconAccountsCompared, ReconMismatches, ReconStaleYearDrift,
             DuplicateGrainRows, UnparsedSegmentRows, Outcome, [Message])
        VALUES
            (SYSDATETIME(), @rows, DATEDIFF(second, @startedAt, SYSDATETIME()), @years, @accounts,
             @approved, @routing, @reconCompared, @reconMismatch, @reconStale,
             @dupGrain, @unparsed, 'OK',
             CASE WHEN @reconStale > 0 OR @dupGrain > 0 OR @unparsed > 0
                  THEN N'Loaded with observations: '
                     + CONVERT(nvarchar(20), @reconStale) + N' account(s) drift against STALE ledger years (expect the next full ledger rebuild to move them); '
                     + CONVERT(nvarchar(20), @dupGrain)   + N' duplicate grain row(s); '
                     + CONVERT(nvarchar(20), @unparsed)   + N' row(s) with an unparseable account number (invisible to every user - same in Phase 1).'
                  ELSE NULL END);

    COMMIT TRANSACTION;

    DELETE FROM dbo.FinanceRequisitionSnapshot_Staging;

    /* Trim the log. Keyed on RunId rather than a date so retention is a count
       of runs, which is what someone reading it actually wants. */
    DELETE FROM dbo.FinanceRequisitionRefresh
    WHERE RunId < (
        SELECT MIN(RunId) FROM (
            SELECT TOP (@KeepRuns) RunId FROM dbo.FinanceRequisitionRefresh ORDER BY RunId DESC
        ) AS keep
    );

    DROP TABLE #Shipments;
    DROP TABLE #GoodsSvc;

    SELECT
        @rows          AS RowsLoaded,
        DATEDIFF(second, @startedAt, SYSDATETIME()) AS DurationSeconds,
        @years         AS FiscalYearsLoaded,
        @accounts      AS AccountsLoaded,
        @approved      AS TotalApproved,
        @routing       AS TotalRouting,
        @reconCompared AS ReconAccountsCompared,
        @reconMismatch AS ReconMismatches,
        @reconStale    AS ReconStaleYearDrift,
        @dupGrain      AS DuplicateGrainRows,
        @unparsed      AS UnparsedSegmentRows;
END
GO


/* ===========================================================================
   5. Read surfaces
   ---------------------------------------------------------------------------
   TWO VIEWS, ONE DIFFERENCE: the goods-and-services filter.

   *** "Unscoped" REFERS TO THE GOODS-AND-SERVICES SCOPE, NOT USER ACCESS. ***

   Both views apply the three-way access join. There is no unscoped-by-user
   surface and there must never be one - that join is the confidentiality
   control that closed a measured TTD 99.1M cross-institution exposure. If you
   need a user-agnostic read for diagnosis, query dbo.FinanceRequisitionSnapshot
   directly and know that you are doing it.

   The choice between the two, the measurements behind it and the trade-off are
   documented in sql/Phase2ScopeVariants.md. Short version: the SCOPED view is
   the default and the only one that can reconcile to the summary. Exposing the
   unscoped one on a page would reintroduce exactly the summary/detail
   disagreement this phase exists to prevent.

   Column names match the reference queries' final SELECT, so a query written
   against those files ports across unchanged: ActBalance surfaces as Quantity,
   ActCost as ExtendedCost.
   =========================================================================== */
CREATE OR ALTER VIEW dbo.vw_FinanceRequisitionDetail
AS
SELECT
    ua.UserName,
    s.FinancialYear,
    s.FinancialYear AS FinYear,          -- the reference queries' name for it
    s.RequisitionNumber,
    s.PONumber,
    s.LineNbr,
    s.[Status],
    s.StatusName,
    s.OwnerID,
    s.[Name],
    s.ItemID,
    s.ItemDescription,
    s.SiteID,
    s.SiteLocation,
    s.ReqDateCreated,
    s.UofM,
    s.CurrencyID,
    s.VendorID,
    s.VendorName,
    s.AccountNumber,
    s.AccountNumber AS GLAccount,        -- ditto
    s.AccountDescription,
    s.AccountSegment,
    s.AccountSegment AS AccountN,        -- ditto
    s.InstitutionID,
    s.ResponsibilityID,
    s.DepartmentID,
    s.Cluster,
    s.Institution,
    s.Department,
    s.ResponsibilityCentre,
    s.OrderQuantity,
    s.QtyShipped,
    s.ActBalance AS Quantity,            -- the UNSHIPPED balance, not the order qty
    s.UnitCost,
    s.ActCost    AS ExtendedCost         -- net of receipts, floored at zero
FROM dbo.FinanceRequisitionSnapshot AS s
INNER JOIN dbo.vw_WebAppUserAccess AS ua
    ON ua.InstitutionID    = s.InstitutionID
   AND ua.ResponsibilityID = s.ResponsibilityID
   AND ua.DepartmentID     = s.DepartmentID
WHERE s.IsGoodsAndServices = 1;
GO

CREATE OR ALTER VIEW dbo.vw_FinanceRequisitionDetailUnscoped
AS
SELECT
    ua.UserName,
    s.FinancialYear,
    s.FinancialYear AS FinYear,
    s.RequisitionNumber,
    s.PONumber,
    s.LineNbr,
    s.[Status],
    s.StatusName,
    s.OwnerID,
    s.[Name],
    s.ItemID,
    s.ItemDescription,
    s.SiteID,
    s.SiteLocation,
    s.ReqDateCreated,
    s.UofM,
    s.CurrencyID,
    s.VendorID,
    s.VendorName,
    s.AccountNumber,
    s.AccountNumber AS GLAccount,
    s.AccountDescription,
    s.AccountSegment,
    s.AccountSegment AS AccountN,
    s.InstitutionID,
    s.ResponsibilityID,
    s.DepartmentID,
    s.Cluster,
    s.Institution,
    s.Department,
    s.ResponsibilityCentre,
    s.OrderQuantity,
    s.QtyShipped,
    s.ActBalance AS Quantity,
    s.UnitCost,
    s.ActCost    AS ExtendedCost,
    s.IsGoodsAndServices                 -- so a caller can see WHICH rows the scoped view drops
FROM dbo.FinanceRequisitionSnapshot AS s
INNER JOIN dbo.vw_WebAppUserAccess AS ua
    ON ua.InstitutionID    = s.InstitutionID
   AND ua.ResponsibilityID = s.ResponsibilityID
   AND ua.DepartmentID     = s.DepartmentID;
GO


/* ===========================================================================
   VERIFICATION - run these after the first build and READ the results
   ---------------------------------------------------------------------------
   Every figure below is a MEASUREMENT, not an invariant. The production
   baselines quoted in financesqlupdatep2.md are from 2026-08-26 and describe
   that day's data. Re-measure; never quote.
   =========================================================================== */

/* 1. The run itself. Outcome must be OK. A non-zero ReconMismatches on an OK
      row is impossible - the gate aborts - so this is really about reading
      ReconStaleYearDrift and the two observation counters. */
SELECT TOP (5) * FROM dbo.FinanceRequisitionRefresh ORDER BY RunId DESC;
GO

/* 2. Shape by fiscal year. FY2022 and FY2023 legitimately have NO rows.
      Measured 2026-08-26: FY2026 20,647 / FY2025 16,538 / FY2024 14,163,
      ~106,400 across 15 years. */
SELECT FinancialYear,
       COUNT(*)                                                      AS rows_,
       SUM(CASE WHEN [Status] IN ('AP','PO')      THEN 1 ELSE 0 END) AS approved_rows,
       SUM(CASE WHEN [Status] IN ('RT','HD','PN') THEN 1 ELSE 0 END) AS routing_rows,
       COUNT(DISTINCT AccountNumber)                                 AS accounts,
       SUM(CASE WHEN IsGoodsAndServices = 0 THEN 1 ELSE 0 END)       AS off_line3_rows
FROM dbo.FinanceRequisitionSnapshot
GROUP BY FinancialYear
ORDER BY FinancialYear DESC;
GO

/* 3. FAN-OUT CHECK on the SCOPED view. Must return NOTHING. Any row here means
      vw_WebAppUserAccess is emitting more than one row per access tuple and
      every money figure on those lines is being multiplied - the exact defect
      the three-way DISTINCT exists to prevent. */
SELECT TOP (10) 'FAN-OUT - money is multiplying' AS alert,
       UserName, FinancialYear, RequisitionNumber, PONumber, LineNbr, COUNT(*) AS times_matched
FROM dbo.vw_FinanceRequisitionDetail
GROUP BY UserName, FinancialYear, RequisitionNumber, PONumber, LineNbr
HAVING COUNT(*) > 1;
GO

/* 4. Reconciliation, read back per user against the LIVE summary view. This is
      the user-scoped statement that sql/Phase2ReconciliationTest.sql makes; the
      build gate makes the stronger user-agnostic one. Both diffs must be 0.00.

      Measured on production 2026-08-26 for KCHARLES1 / FY2026:
        Approved  3,408 rows / TTD 41,936,916.59  (145 accounts carry rows)
        Routing     773 rows / TTD  4,512,250.19  (120 accounts)             */
SELECT
    d.UserName,
    d.FinancialYear,
    ROUND(SUM(CASE WHEN d.[Status] IN ('AP','PO')      THEN d.ExtendedCost ELSE 0 END), 2) AS detail_approved,
    ROUND(SUM(CASE WHEN d.[Status] IN ('RT','HD','PN') THEN d.ExtendedCost ELSE 0 END), 2) AS detail_routing,
    ROUND(l.summary_approved, 2) AS summary_approved,
    ROUND(l.summary_routing,  2) AS summary_routing,
    ROUND(SUM(CASE WHEN d.[Status] IN ('AP','PO')      THEN d.ExtendedCost ELSE 0 END) - l.summary_approved, 2) AS diff_approved,
    ROUND(SUM(CASE WHEN d.[Status] IN ('RT','HD','PN') THEN d.ExtendedCost ELSE 0 END) - l.summary_routing,  2) AS diff_routing
FROM dbo.vw_FinanceRequisitionDetail AS d
INNER JOIN (
    SELECT UserName, FinancialYear,
           SUM(Approved) AS summary_approved,
           SUM(Routing)  AS summary_routing
    FROM dbo.vw_FinanceLedger
    GROUP BY UserName, FinancialYear
) AS l ON l.UserName = d.UserName AND l.FinancialYear = d.FinancialYear
GROUP BY d.UserName, d.FinancialYear, l.summary_approved, l.summary_routing
ORDER BY d.UserName, d.FinancialYear DESC;
GO

/* 5. What the scoped view drops. Measured 2026-08-26 for KCHARLES1 / FY2026:
      exactly 2 accounts, both genuinely off reporting line 3 -
      4-80600-H01-401-0627-00-000 and 4-81500-H01-307-0601-00-000. */
SELECT DISTINCT AccountNumber, AccountDescription, FinancialYear
FROM dbo.vw_FinanceRequisitionDetailUnscoped
WHERE IsGoodsAndServices = 0
ORDER BY FinancialYear DESC, AccountNumber;
GO
