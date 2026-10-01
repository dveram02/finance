/* ===========================================================================
   FinanceRequisitionParityCutover.sql
   ---------------------------------------------------------------------------
   Phase 2's half of the Access-parity change. MUST be applied in the same
   window as sql/FinanceLedgerParityCutover.sql.

   Design: financeupdatesep.md (A7). Status: financeupdatesepprogress.md.

   WHY IT IS NOT OPTIONAL
     Gate F in this procedure reconciles the requisition-line detail to
     dbo.FinanceLedgerSnapshot's Approved/Routing per account, and it is NEVER
     bypassed by @Force - deliberately, because that reconciliation is the entire
     justification for Phase 2 being snapshot-backed. So:
       - ledger on parity + requisition still floored -> gate F aborts on the 62
         over-shipped FY2026 accounts, every night.
       - requisition unfloored + ledger still one-row-per-account -> gate F
         aborts on the 11 split accounts, every night.
     Neither half works alone. The Agent job must stay disabled until both are
     applied and GATE 3 has passed.

   WHAT CHANGES
     1. ActCost / ActBalance lose the zero floor, and ActCost is rounded after
        multiplying in float from the raw columns, matching the ledger's
        per-line expression exactly so gate F can tie to the cent.
     2. Gate F's LEDGER side is aggregated by (FinancialYear, AccountNumber), so
        a split account presents as one row to the comparison. This changes the
        gate's internal comparison only - the displayed grain is untouched.
     Nothing else in the procedure moves. #Shipments and its UNIQUE CLUSTERED
     INDEX stay exactly as they were.

   WHAT THE USER WILL SEE
     Negative Quantity and Extended Cost on Encumbered Details for over-received
     lines - 694 FY2026 lines across 62 accounts. App\Concerns\DerivesRequisitionDetail
     flags these OverShipped so the row reads honestly rather than being muted.

   ROLLBACK: re-run sql/FinanceRequisition.sql (idempotent CREATE OR ALTER, and
   it still holds the floored definitions), then EXEC dbo.usp_RefreshFinanceRequisition
   @Force = 1. Roll the ledger back in the same window or gate F will abort.

   RUN ORDER (continuing from the ledger cutover)
     4. this script
     5. EXEC dbo.usp_RefreshFinanceRequisition @Force = 1                 <- GATE 3
        Requires ReconMismatches = 0 AND ReconStaleYearDrift = 0.
     6. EXEC dbo.usp_RefreshFinanceLedgerSnapshotAll @Force = 1           <- all years
     7. EXEC dbo.usp_RefreshFinanceRequisition @Force = 1                 <- re-tie after 6

   Step 5 runs BEFORE the all-years ledger rebuild on purpose: at that point only
   FY2026 has been rebuilt on parity, so gate F's 36-hour freshness window covers
   FY2026 and records the older years as ReconStaleYearDrift rather than aborting
   on them. Step 7 is what proves every year ties once they are all on parity.
   =========================================================================== */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

USE FinanceAutomationSystem;
GO

/* ===========================================================================
   dbo.usp_RefreshFinanceRequisition - unfloored ActCost, aggregated gate F.
   Two changes, both commented inline at the point of change.
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

    /* ActBalance / ActCost - ACCESS PARITY, changed 2026-09-29. This block used
       to floor the balance at zero and multiply in decimal, and carried a "do
       not simplify this back" warning. That warning was right for its time; the
       business has since decided the portal must reproduce Finance's Access
       query exactly, including this. See financeupdatesep.md.

       WHAT CHANGED, AND WHY EACH HALF IS SHAPED THE WAY IT IS:

       1. NO ZERO FLOOR. ActBalance is now SIGNED, so an over-received line is a
          NEGATIVE commitment. Measured 2026-09-29: 694 FY2026 lines across 62
          accounts, -17,363,584.00 raw. The app reads this through
          vw_FinanceRequisitionDetail as Quantity/ExtendedCost, so negative
          figures now reach the page and the CSV by design - see
          App\Concerns\DerivesRequisitionDetail, which flags them OverShipped.

       2. ROUND AFTER MULTIPLYING, IN FLOAT, FROM THE RAW COLUMNS - deliberately
          NOT from b.ActBalance. Gate F below compares SUM(ActCost) per account
          against dbo.FinanceLedgerSnapshot's Approved/Routing to the cent, and
          the ledger computes its per-line cost as
              ROUND((Quantity - QtyShipped) * UnitCost, 2)
          in float (0040DBudgetsEncumbrance.Quantity and UnitCost are float).
          Deriving ActCost from the decimal-converted ActBalance instead would
          round differently on a .xx5 boundary and break the tie for that
          account. The two sides must use the SAME arithmetic, so this mirrors
          dbo.fn_FinanceLedgerSource's encLines CTE expression for expression.

       3. SHIPMENTS STAY PRE-AGGREGATED (#Shipments, with its UNIQUE CLUSTERED
          INDEX). Not a parity deviation: measured 2026-09-29, ZERO open
          encumbrance lines match a duplicated (PONumber, POLineID) in ANY
          fiscal year, so the raw join and the pre-aggregate return identical
          rows. Keeping the aggregate keeps the index's uniqueness assertion.
          Gate 4e in sql/FinanceLedgerParityCutover.sql is the tripwire if that
          ever stops being true. */
    CROSS APPLY (
        SELECT CONVERT(decimal(19,4),
                   ISNULL(e.Quantity, 0) - ISNULL(s.QtyShipped, 0)) AS ActBalance
    ) AS b
    CROSS APPLY (
        SELECT CONVERT(decimal(19,4),
                   ROUND((ISNULL(e.Quantity, 0) - ISNULL(s.QtyShipped, 0))
                         * ISNULL(e.UnitCost, 0), 2)) AS ActCost
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
        /* AGGREGATED, added 2026-09-29 with Access parity. The ledger snapshot is
           no longer one row per account: where the GL master and the COA
           corrections spell a description differently, Access splits the account
           and so do we (24 accounts across FY2014-FY2026; FY2026 = 11). Without
           this GROUP BY a split account yields TWO p1 rows against ONE p2 row,
           and the FULL OUTER JOIN makes BOTH report a drift equal to the other
           half - so every split account would fail this gate every night, and
           @Force does not bypass it.

           This changes the gate's INTERNAL comparison only. It does NOT change
           the displayed grain: vw_FinanceLedger is untouched and the pages still
           show the split rows. @reconCompared falls by the number of splits,
           which is recorded rather than gated.

           Do not remove this as redundant. It is load-bearing. */
        FULL OUTER JOIN (
            SELECT FinancialYear, AccountNumber,
                   SUM(Approved) AS Approved,
                   SUM(Routing)  AS Routing
            FROM dbo.FinanceLedgerSnapshot
            GROUP BY FinancialYear, AccountNumber
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
   Verification. DELIBERATELY CHEAP.

   Everything here is metadata or reads the existing snapshot. Nothing rebuilds
   ActCost and nothing EXCEPTs two table-valued functions - that is what raised
   Msg 701 (insufficient system memory, max server memory 2048 MB on the test
   instance) in the ledger cutover's first footer. The expensive proof is GATE 3
   itself, which the procedure performs internally against staging.
   =========================================================================== */
SET NOCOUNT ON;

-- 1. Both changes are actually in the deployed body.
DECLARE @def nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_RefreshFinanceRequisition'));

SELECT 'DEPLOYED_BODY' AS chk,
    CASE WHEN @def LIKE '%ELSE CONVERT(decimal(19,4), 0)%' THEN 'FAIL - zero floor still present'
         ELSE 'ok - floor removed' END AS floor_state,
    CASE WHEN @def LIKE '%GROUP BY FinancialYear, AccountNumber%' THEN 'ok - gate F aggregated'
         ELSE 'FAIL - gate F ledger side not aggregated' END AS gatef_state,
    CASE WHEN @def LIKE '%CREATE UNIQUE CLUSTERED INDEX CIX_Shipments%' THEN 'ok - pre-aggregate kept'
         ELSE 'FAIL - #Shipments assertion lost' END AS shipments_state;

-- 2. The ledger side must be on parity already, or GATE 3 cannot pass.
SELECT 'LEDGER_READY' AS chk,
    CASE WHEN OBJECT_DEFINITION(OBJECT_ID('dbo.fn_FinanceLedgerSource')) LIKE '%draftCorr%'
         THEN 'ok - ledger function is on parity' ELSE 'FAIL - run sql/FinanceLedgerParityCutover.sql first' END AS fn_state,
    /* Years whose snapshot rows actually carry AccountID, i.e. were rebuilt by the
       parity function. Must be 13 before GATE 3 - a year still on the pre-parity
       basis will disagree with the unfloored detail and be recorded as drift.

       Do NOT count `SplitAccountCount > 0` here, as an earlier version did: only
       7 of the 13 years have any split, so that reported 7 for a complete rebuild
       and read like 6 missing years. */
    (SELECT COUNT(DISTINCT r.FinancialYear)
     FROM dbo.FinanceLedgerRefresh AS r
     WHERE r.Outcome = 'OK'
       AND EXISTS (SELECT 1 FROM dbo.FinanceLedgerSnapshot AS s
                   WHERE s.FinancialYear = r.FinancialYear AND s.AccountID IS NOT NULL)) AS years_rebuilt_on_parity,
    (SELECT COUNT(*) FROM dbo.FinanceLedgerRefresh WHERE Outcome = 'OK' AND SplitAccountCount > 0) AS years_with_splits,
    (SELECT MAX(RefreshedAt) FROM dbo.FinanceLedgerRefresh WHERE Outcome = 'OK') AS ledger_last_ok;

-- 3. The Agent job must be OFF until GATE 3 has passed.
SELECT 'AGENT_JOB' AS chk, name,
       CASE WHEN enabled = 1 THEN 'ENABLED - disable it before GATE 3' ELSE 'ok - disabled' END AS state
FROM msdb.dbo.sysjobs WHERE name = N'SWRHA Finance - Ledger Refresh';
GO
