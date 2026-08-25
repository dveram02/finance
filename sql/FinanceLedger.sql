/* ===========================================================================
   FinanceLedger.sql
   ---------------------------------------------------------------------------
   Unified ledger layer for the Finance Automation portal.

   Adopts "SQL Revised Web App.sql" as the single source for Budget
   Allocations, Monthly Expenditure, the Dashboard, Department Expenditure and
   Allocation Line Expenditure.

   Objects created (all in FinanceAutomationSystem):

     dbo.vw_WebAppUserAccess               live view - who may see which dept
     dbo.fn_FinanceLedgerSource(@FY)       inline TVF - the corrected script
     dbo.FinanceLedgerSnapshot             indexed materialisation
     dbo.FinanceLedgerSnapshot_Staging     build target
     dbo.FinanceLedgerRefresh              freshness / outcome metadata
     dbo.vw_FinanceLedger                  the app's read surface
     dbo.usp_RefreshFinanceLedgerSnapshot  refresh one fiscal year
     dbo.usp_RefreshFinanceLedgerSnapshotAll

   This script is idempotent and ASCII-only (SSMS can misread UTF-8 with no
   BOM). It does NOT redefine dbo.MonthlyExpenditure or dbo.vw_BudgetAllocation
   - that is the cutover, in sql/FinanceLedgerCutover.sql, and must not run
   until reconciliation has passed.

   Run order:
     1. sql/FinanceLedger.sql          (this file)
     2. EXEC dbo.usp_RefreshFinanceLedgerSnapshotAll
     3. reconcile against the legacy views
     4. sql/FinanceLedgerCutover.sql

   TIMINGS. Build cost for ONE fiscal year, no user pruning:
     replica  (V165ICTFA0MEL\SQLEXPRESS, max server memory 2048 MB) ... ~93s
     PRODUCTION (sqlapp\SQLEXPRESS, Standard Edition) ............ 74 - 175s
   The production spread is real: that box serves live Access users, and the
   same statement was sampled at both ends. Budget 16-38 minutes for all 13
   fiscal years, and set FINANCE_LEDGER_REFRESH_TIMEOUT accordingly.

   WHERE THE TIME GOES - measured on production, contrary to what an earlier
   version of this header claimed:
     reading the fact tables ..................... ~1s TOTAL
       (glData 0.84s, allocation 0.02s, encumbrance 0.03s, varianceLines 0.01s)
     everything else ............................. the remaining 72s+
   The 6.38M-row scan of 0098AFinGLMaster is NOT the dominant cost, and the
   FinancialYear index is NOT the lever - see the OPTIONAL INDEX section at the
   foot of this file. The cost is in the account-base UNION, the CROSS APPLY
   splitter and the join chain, which remain unprofiled.
   =========================================================================== */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

/* ===========================================================================
   1. dbo.vw_WebAppUserAccess  -  DEFINED ELSEWHERE, DELIBERATELY
   ---------------------------------------------------------------------------
   Lives in sql/FinanceLedgerOversightCutover.sql together with
   dbo.vw_FinanceLedger, because the two MUST be applied in the same
   transaction. See the note at section 4 below for why - in short, this view
   emits two rows for the 32 (Responsibility, Department) pairs that span
   institutions, and any moment where that is live against a two-column ledger
   join doubles their money.

   Nothing in THIS file depends on it: the snapshot is user-agnostic and the
   refresh procs never read it. It is joined on live by vw_FinanceLedger so
   that a permission change takes effect on the next request, with no refresh.
   =========================================================================== */

/* ===========================================================================
   2. dbo.fn_FinanceLedgerSource
   ---------------------------------------------------------------------------
   "SQL Revised Web App.sql", corrected, with the fiscal year as a REQUIRED
   parameter pushed into glData, allocationData and the encumbrance date
   bounds, where it is sargable. Not a nullable "all years" parameter -
   WHERE (@FY IS NULL OR FinancialYear = @FY) is the classic catch-all that
   defeats sargability. Full rebuilds loop the years instead.

   SOURCE OF TRUTH (since 2026-08-25):
     sql/source/SQL Revised Allocation Oversight F.sql
     SHA-256 9f9f615854ed1ac5394b4b0da519e09d1df0cb8d665dc4d481ac8e5caef1d3ba
   "SQL Revised Web App.sql" in the repo root is the superseded predecessor and
   is retained for history only.

   Corrections against the source script, in order of severity. It is a working
   draft written in the same loose style as its predecessor, and reintroduces
   several defects that were already fixed here:

   (a) Drives from a COMPLETE account base - the UNION of account numbers
       appearing in GL, allocation and encumbrance - not from glData alone.
       The source LEFT JOINs allocation onto GL, so an account with a budget
       but no GL activity never appears. Measured FY2026: 1,117 such accounts
       holding TTD 21,128,414.88. Migrating as written would silently cut that
       from the Total Budget KPI.

   (b) User access is NOT hung off the chart of accounts. Segments are parsed
       from the account NUMBER, and the access join lives in vw_FinanceLedger.
       A missing chart-of-accounts row costs a LABEL, never a row and never
       money. Hanging access off coaData would re-lose the TTD 21.1M in (a),
       one step later, because 0040CBudgetsAllocation has no AccountID.

   (c) The chart of accounts is now the LOCAL mirror - 0030ADGPCOA plus
       0030AEAccountNameCorrections - as the source script does. The
       GL40200 / 0000CSegmentControls / DBA_Clusters chain is gone, so the
       ledger refresh has NO linked-server dependency at all. That also
       retires the linked-server gate in sql/FinanceLedgerAgentJob.sql, which
       existed solely to protect these reads.

   (d) Money is CONVERTed to decimal(19,4) BEFORE aggregating. The source
       columns are float; summing floats and rounding afterwards preserves the
       accumulation error, converting first is exact.

   (e) The hardcoded byte offsets - substring(AccountNumber,3,5), (9,3),
       (13,3), (17,4) - are replaced by the CHARINDEX splitter. Those offsets
       assume every account is exactly 1-5-3-3-4. Measured 2026-08-25: 4
       distinct account numbers are 26 characters rather than 27, so a segment
       is short and every offset past it slides, silently mis-parsing into the
       WRONG DEPARTMENT. NULLIF(...,0) makes a malformed account yield NULL
       segments, which simply fail to match, rather than raising an error.

   (f) FORMAT(TRXDate,'MMM') is replaced by MONTH(). FORMAT is a per-row CLR
       call and culture-dependent - under a non-English session language it
       returns abbreviations matching no PIVOT column, producing silent zeros
       rather than an error. Conditional SUM also drops the PIVOT entirely.

   (g) The nvarchar/int join is gone. Encumbrance is filtered on sargable DATE
       bounds instead of a per-row CASE on YEAR(CAST(ReqDateCreated AS DATE)).

   (h) The trailing ORDER BY is dropped - invalid in a set-returning object
       without TOP. Ordering is the caller's business.

   (i) The source's userAccess CTE drops the 0006A.IsActive filter, which
       would grant DEACTIVATED accounts data access. Both IsActive filters are
       kept - see dbo.vw_WebAppUserAccess.

   (j) Encumbrance is net of receipts: ActCost = (Quantity - QtyShipped) x
       UnitCost, pre-aggregated so the join cannot fan out and floored at zero
       so an over-shipped line is not a negative commitment. See the CTE.

   Naming: descriptions resolve curated correction -> GL master -> local COA
   -> 'UNDEFINED'. Segment names come from the local COA mirror, with REMOVE
   and UNDEFINED sentinels normalised to NULL so the final ISNULL is the only
   place a missing label is named.

   TIMINGS. The pre-Oversight build measured 102-256s per fiscal year on
   production, dominated by the join/assembly phase rather than by reading the
   fact tables. Removing the linked server should improve this materially;
   RE-MEASURE on first deployment and update this note - the old figures no
   longer describe this function.

   =========================================================================== */
CREATE OR ALTER FUNCTION dbo.fn_FinanceLedgerSource
(
    @FinancialYear varchar(10)
)
RETURNS TABLE
AS
RETURN
(
    WITH corrections AS (
        -- Curated account descriptions. Grain is enforced permanently by the
        -- refresh proc (gate 4a); this GROUP BY is defence in depth, so a
        -- duplicate row cannot multiply money even if that gate is bypassed.
        --
        -- Measured 2026-08-25: 190 rows over 168 accounts. Duplicates DO
        -- exist, but every duplicate set agrees on the description, so the
        -- collapse is lossless. 153 rows have a NULL EditedAccountDescription
        -- and NONE has a blank string - the NULLIF is hardening, not a fix to
        -- an observed bug.
        --
        -- IsDuplicate exists on this table but is 0 on every row. Do NOT
        -- adopt it as a tie-break without confirming its meaning with the
        -- finance team.
        SELECT
            UPPER(LTRIM(RTRIM(AccountNumber))) COLLATE Latin1_General_CI_AS AS AccountSeg,
            MIN(COALESCE(
                NULLIF(LTRIM(RTRIM(EditedAccountDescription)), ''),
                NULLIF(LTRIM(RTRIM(AccountDescription)),       '')
            )) AS CorrectedDescription
        FROM [FinanceAutomationSystem].[dbo].[0030AEAccountNameCorrections]
        GROUP BY UPPER(LTRIM(RTRIM(AccountNumber)))
    ),
    -- Replaces the GL40200 / 0000CSegmentControls / DBA_Clusters chain that
    -- reached across the linked server for every segment name. The local
    -- mirror carries all four names directly, so the ledger refresh now has
    -- NO linked-server dependency at all - which also retires the linked
    -- server gate in sql/FinanceLedgerAgentJob.sql.
    --
    -- Sentinels are normalised to NULL HERE so that ISNULL(..., 'UNDEFINED')
    -- in the final SELECT is the single place a missing label gets named.
    -- Measured 2026-08-25: 24 DepartmentName and 1 ResponsibilityName carry
    -- REMOVE/UNDEFINED; InstitutionName and Cluster carry none.
    coaData AS (
        SELECT
            UPPER(LTRIM(RTRIM(c.AccountNumber))) COLLATE Latin1_General_CI_AS AS AccountNumber,
            NULLIF(NULLIF(NULLIF(LTRIM(RTRIM(c.Cluster)),            ''), 'REMOVE'), 'UNDEFINED') AS ClusterName,
            NULLIF(NULLIF(NULLIF(LTRIM(RTRIM(c.InstitutionName)),    ''), 'REMOVE'), 'UNDEFINED') AS InstitutionName,
            NULLIF(NULLIF(NULLIF(LTRIM(RTRIM(c.ResponsibilityName)), ''), 'REMOVE'), 'UNDEFINED') AS ResponsibilityName,
            NULLIF(NULLIF(NULLIF(LTRIM(RTRIM(c.DepartmentName)),     ''), 'REMOVE'), 'UNDEFINED') AS DepartmentName,
            -- 100% populated (9,463 of 9,463, measured 2026-08-25). This is the
            -- last-resort name for an allocation-only account that has neither a
            -- correction row nor any GL activity to borrow a description from.
            NULLIF(LTRIM(RTRIM(c.AccountDescription)), '') AS CoaAccountDescription
        FROM [FinanceAutomationSystem].[dbo].[0030ADGPCOA] AS c
    ),
    -- SEGMENT-LEVEL FALLBACK. coaData matches on the FULL account number, so
    -- an account missing from the mirror entirely would lose all four labels
    -- at once. Measured 2026-08-25: 2 of 2,236 FY2026 accounts are absent
    -- (4-80300-H01-401-0627-00-000 and 4-89000-H04-208-0376-00-000), and the
    -- retired segment-based chain named them correctly. These CTEs restore
    -- that resilience.
    --
    -- Safe because segment -> name is 1:1 across the whole COA: measured 0
    -- ambiguous segments for department, institution AND responsibility. The
    -- MIN() is belt-and-braces so a future ambiguity yields one deterministic
    -- name rather than duplicating the account row.
    deptSeg AS (
        SELECT
            UPPER(LTRIM(RTRIM(AccountSegment5))) COLLATE Latin1_General_CI_AS AS Seg,
            MIN(NULLIF(NULLIF(NULLIF(LTRIM(RTRIM(DepartmentName)), ''), 'REMOVE'), 'UNDEFINED')) AS Name
        FROM [FinanceAutomationSystem].[dbo].[0030ADGPCOA]
        GROUP BY UPPER(LTRIM(RTRIM(AccountSegment5)))
    ),
    respSeg AS (
        SELECT
            UPPER(LTRIM(RTRIM(AccountSegment4))) COLLATE Latin1_General_CI_AS AS Seg,
            MIN(NULLIF(NULLIF(NULLIF(LTRIM(RTRIM(ResponsibilityName)), ''), 'REMOVE'), 'UNDEFINED')) AS Name
        FROM [FinanceAutomationSystem].[dbo].[0030ADGPCOA]
        GROUP BY UPPER(LTRIM(RTRIM(AccountSegment4)))
    ),
    instSeg AS (
        SELECT
            UPPER(LTRIM(RTRIM(AccountSegment3))) COLLATE Latin1_General_CI_AS AS Seg,
            MIN(NULLIF(NULLIF(NULLIF(LTRIM(RTRIM(InstitutionName)), ''), 'REMOVE'), 'UNDEFINED')) AS Name,
            MIN(NULLIF(NULLIF(NULLIF(LTRIM(RTRIM(Cluster)), ''), 'REMOVE'), 'UNDEFINED')) AS ClusterName
        FROM [FinanceAutomationSystem].[dbo].[0030ADGPCOA]
        GROUP BY UPPER(LTRIM(RTRIM(AccountSegment3)))
    ),
    -- Reporting line 3: the 41 goods-and-services account codes. Payroll is
    -- excluded by design - see CLAUDE.md. Verified 41 rows / 41 distinct
    -- accounts on the replica, so this INNER JOIN cannot fan out.
    varianceLines AS (
        SELECT
            CAST(C.AccountNumber AS varchar(50)) COLLATE Latin1_General_CI_AS AS AccountSeg,
            B.LineNumber,
            B.LineDescription,
            LTRIM(RTRIM(PARSENAME(REPLACE(REPLACE(B.LineDescription, '.', ' '), ' : ', ' . '), (LEN(B.LineDescription) - LEN(REPLACE(B.LineDescription, ':', '')) + 1)))) AS MainGroup,
            LTRIM(RTRIM(PARSENAME(REPLACE(REPLACE(B.LineDescription, '.', ' '), ' : ', ' . '), (LEN(B.LineDescription) - LEN(REPLACE(B.LineDescription, ':', '')))))) AS SubGroupA,
            LTRIM(RTRIM(PARSENAME(REPLACE(REPLACE(B.LineDescription, '.', ' '), ' : ', ' . '), (LEN(B.LineDescription) - LEN(REPLACE(B.LineDescription, ':', '')) - 1)))) AS SubGroupB
        FROM [FinanceAutomationSystem].[dbo].[0030AACOAReports] AS A
        INNER JOIN [FinanceAutomationSystem].[dbo].[0030ABCOAReportlines] AS B
            ON A.LineID = B.ReportID
        INNER JOIN [FinanceAutomationSystem].[dbo].[0030ACCOAReportAccounts] AS C
            ON B.LineNumber = C.ReportingLineID
        WHERE A.LineID = 3
          AND B.LineDescription NOT LIKE '%TOTAL%'
    ),
    glData AS (
        SELECT
            UPPER(LTRIM(RTRIM(g.AccountNumber))) COLLATE Latin1_General_CI_AS AS AccountNumber,
            MAX(g.AccountDescription) AS AccountDescription,
            SUM(CASE WHEN MONTH(g.TRXDate) = 10 THEN CONVERT(decimal(19,4), g.NetChange) ELSE 0 END) AS [Oct],
            SUM(CASE WHEN MONTH(g.TRXDate) = 11 THEN CONVERT(decimal(19,4), g.NetChange) ELSE 0 END) AS [Nov],
            SUM(CASE WHEN MONTH(g.TRXDate) = 12 THEN CONVERT(decimal(19,4), g.NetChange) ELSE 0 END) AS [Dec],
            SUM(CASE WHEN MONTH(g.TRXDate) =  1 THEN CONVERT(decimal(19,4), g.NetChange) ELSE 0 END) AS [Jan],
            SUM(CASE WHEN MONTH(g.TRXDate) =  2 THEN CONVERT(decimal(19,4), g.NetChange) ELSE 0 END) AS [Feb],
            SUM(CASE WHEN MONTH(g.TRXDate) =  3 THEN CONVERT(decimal(19,4), g.NetChange) ELSE 0 END) AS [Mar],
            SUM(CASE WHEN MONTH(g.TRXDate) =  4 THEN CONVERT(decimal(19,4), g.NetChange) ELSE 0 END) AS [Apr],
            SUM(CASE WHEN MONTH(g.TRXDate) =  5 THEN CONVERT(decimal(19,4), g.NetChange) ELSE 0 END) AS [May],
            SUM(CASE WHEN MONTH(g.TRXDate) =  6 THEN CONVERT(decimal(19,4), g.NetChange) ELSE 0 END) AS [Jun],
            SUM(CASE WHEN MONTH(g.TRXDate) =  7 THEN CONVERT(decimal(19,4), g.NetChange) ELSE 0 END) AS [Jul],
            SUM(CASE WHEN MONTH(g.TRXDate) =  8 THEN CONVERT(decimal(19,4), g.NetChange) ELSE 0 END) AS [Aug],
            SUM(CASE WHEN MONTH(g.TRXDate) =  9 THEN CONVERT(decimal(19,4), g.NetChange) ELSE 0 END) AS [Sep]
        FROM [FinanceAutomationSystem].[dbo].[0098AFinGLMaster] AS g
        WHERE g.FinancialYear = @FinancialYear
          AND g.TRXDate IS NOT NULL          -- a NULL date would vanish into no month
          AND g.AccountNumber IS NOT NULL
        GROUP BY UPPER(LTRIM(RTRIM(g.AccountNumber)))
    ),
    allocationData AS (
        SELECT
            UPPER(LTRIM(RTRIM(AccountNumber))) COLLATE Latin1_General_CI_AS AS AccountNumber,
            SUM(CONVERT(decimal(19,4), Allocation)) AS Allocation
        FROM [FinanceAutomationSystem].[dbo].[0040CBudgetsAllocation]
        WHERE FinancialYear = @FinancialYear
          AND AccountNumber IS NOT NULL
        GROUP BY UPPER(LTRIM(RTRIM(AccountNumber)))
    ),
    -- FY N runs 1 Oct (N-1) to 30 Sep N. Sargable DATE bounds replace the
    -- original's per-row CASE on YEAR(CAST(ReqDateCreated AS DATE)).
    --
    -- COMMITMENT IS NOW NET OF RECEIPTS. The old basis was raw ExtendedCost,
    -- which double-counts: once as an open commitment here, and again as GL
    -- actual once the goods are received and invoiced. ActCost bills only the
    -- UNSHIPPED balance. Measured FY2026: Approved falls 1,307,659,013.55 ->
    -- 1,288,452,730.24 (-19,206,283.31). Routing is unchanged, because
    -- RT/HD/PN are pre-PO statuses that cannot have shipments - a useful
    -- signal that the join is behaving.
    --
    -- Why not use 0040DBudgetsEncumbrance.Received/.Remaining? Because they
    -- are dead: Received is 0 on all 104,643 rows and Remaining is stale.
    -- The shipment table is the only live source of receipt data.
    --
    -- Encumbrance amounts ARE snapshotted, deliberately. An earlier revision
    -- read them live so balances were accurate intraday; that was reverted
    -- once it was established that nobody uses the balance as a "right now"
    -- figure. One consistent as-of date across GL, allocation and encumbrance
    -- beats mixing live and snapshotted money in the same row.
    --
    -- FAIL CLOSED ON BAD DATA. QTYShipped and POLineID are varchar while
    -- LineNbr is int. CONVERT (not TRY_CONVERT) is deliberate: gate 4d
    -- validates every value before this function runs, so reaching a
    -- CONVERT failure here means the data changed underneath the gate. An
    -- aborted refresh that keeps yesterday's good snapshot is the correct
    -- outcome; silently discarding an unparseable row would understate
    -- shipments and overstate the commitment against a budget.
    encumbranceShipped AS (
        SELECT
            PONumber,
            CONVERT(int, POLineID) AS POLineID,
            SUM(CONVERT(decimal(19,4), QTYShipped)) AS QtyShipped
        FROM [FinanceAutomationSystem].[dbo].[0098FPOShipmentDetails]
        GROUP BY PONumber, CONVERT(int, POLineID)
    ),
    encumbranceData AS (
        SELECT
            UPPER(LTRIM(RTRIM(e.GLAccount))) COLLATE Latin1_General_CI_AS AS AccountNumber,
            CONVERT(decimal(19,4), SUM(CASE WHEN e.Status IN ('AP','PO')      THEN a.ActCost ELSE 0 END)) AS Approved,
            CONVERT(decimal(19,4), SUM(CASE WHEN e.Status IN ('RT','HD','PN') THEN a.ActCost ELSE 0 END)) AS Routing
        FROM [FinanceAutomationSystem].[dbo].[0040DBudgetsEncumbrance] AS e
        -- Pre-aggregated, so this join cannot fan out. 65 (PONumber, POLineID)
        -- keys are duplicated in the shipment table; POLNENUM shows they are
        -- DISTINCT GP lines colliding on an insufficient key, not partial
        -- shipments of one line. None intersects an open encumbrance today,
        -- and gate 4d aborts the refresh if one ever does - summing across two
        -- different GP lines would be wrong, so it must not happen silently.
        LEFT JOIN encumbranceShipped AS s
               ON s.PONumber = e.PONumber
              AND s.POLineID = e.LineNbr
        -- A NULL Quantity or UnitCost would make ActCost NULL, which SUM
        -- silently ignores - an understatement with no error. ISNULL makes it
        -- an explicit zero. (Measured: neither is NULL on any of the 104,643
        -- in-scope rows, so this is hardening.)
        CROSS APPLY (
            SELECT CASE
                WHEN CONVERT(decimal(19,4), ISNULL(e.Quantity, 0)) - ISNULL(s.QtyShipped, 0) > 0
                THEN CONVERT(decimal(19,4), ISNULL(e.Quantity, 0)) - ISNULL(s.QtyShipped, 0)
                -- Floored at zero: an over-shipped line is not a NEGATIVE
                -- commitment. Measured 2026-08-25: 4,365 lines are over-shipped
                -- across all years, carrying TTD 118,656,213.96 that would
                -- otherwise net off other lines' genuine commitments.
                ELSE CONVERT(decimal(19,4), 0)
            END AS ActBalance
        ) AS b
        -- The explicit CONVERT matters: decimal(19,4) * decimal(19,4) infers
        -- decimal(38,8), and letting that propagate would change this
        -- function's return type while the proc's drift guard - which compares
        -- column NAMES only - stayed silent.
        CROSS APPLY (
            SELECT CONVERT(decimal(19,4),
                       b.ActBalance * CONVERT(decimal(19,4), ISNULL(e.UnitCost, 0))) AS ActCost
        ) AS a
        WHERE e.Status IN ('AP','PO','RT','HD','PN')
          AND e.GLAccount IS NOT NULL
          AND e.ReqDateCreated >= DATEFROMPARTS(CONVERT(int, @FinancialYear) - 1, 10, 1)
          AND e.ReqDateCreated <  DATEFROMPARTS(CONVERT(int, @FinancialYear),     10, 1)
        GROUP BY UPPER(LTRIM(RTRIM(e.GLAccount)))
    ),
    -- Correction (a): the complete account base for the year.
    accountBase AS (
        SELECT AccountNumber FROM glData
        UNION
        SELECT AccountNumber FROM allocationData
        UNION
        SELECT AccountNumber FROM encumbranceData
    )
    SELECT
        @FinancialYear AS FinancialYear,
        b.AccountNumber,
        -- Label chain, in priority order:
        --   curated correction -> GL master description -> local COA description
        --   -> 'UNDEFINED'
        -- The COA rung is the one that matters for allocation-only accounts:
        -- they have no GL row to borrow a name from, and not all of them carry
        -- a correction. It is free (coaData is already joined) and 100%
        -- populated, so it can only improve on 'UNDEFINED'.
        CONVERT(nvarchar(255), COALESCE(
            cr.CorrectedDescription,
            NULLIF(LTRIM(RTRIM(g.AccountDescription)), ''),
            c.CoaAccountDescription,
            'UNDEFINED'
        )) AS AccountDescription,
        CONVERT(varchar(50),  seg.InstitutionSeg)    AS InstitutionID,
        CONVERT(varchar(50),  seg.ResponsibilitySeg) AS ResponsibilityID,
        CONVERT(varchar(50),  seg.DepartmentSeg)     AS DepartmentID,
        -- full-account label -> segment-level label -> 'UNDEFINED'
        CONVERT(nvarchar(255), COALESCE(c.ClusterName,        isg.ClusterName, 'UNDEFINED')) AS ClusterName,
        CONVERT(nvarchar(255), COALESCE(c.InstitutionName,    isg.Name,        'UNDEFINED')) AS InstitutionName,
        CONVERT(nvarchar(255), COALESCE(c.ResponsibilityName, rsg.Name,        'UNDEFINED')) AS ResponsibilityName,
        CONVERT(nvarchar(255), COALESCE(c.DepartmentName,     dsg.Name,        'UNDEFINED')) AS DepartmentName,
        vl.LineNumber,
        CONVERT(varchar(255), vl.LineDescription) AS LineDescription,
        CONVERT(varchar(255), vl.MainGroup)       AS MainGroup,
        CONVERT(varchar(255), vl.SubGroupA)       AS SubGroupA,
        CONVERT(varchar(255), vl.SubGroupB)       AS SubGroupB,
        ISNULL(g.[Oct], 0) AS [Oct], ISNULL(g.[Nov], 0) AS [Nov], ISNULL(g.[Dec], 0) AS [Dec],
        ISNULL(g.[Jan], 0) AS [Jan], ISNULL(g.[Feb], 0) AS [Feb], ISNULL(g.[Mar], 0) AS [Mar],
        ISNULL(g.[Apr], 0) AS [Apr], ISNULL(g.[May], 0) AS [May], ISNULL(g.[Jun], 0) AS [Jun],
        ISNULL(g.[Jul], 0) AS [Jul], ISNULL(g.[Aug], 0) AS [Aug], ISNULL(g.[Sep], 0) AS [Sep],
        ISNULL(g.[Oct],0) + ISNULL(g.[Nov],0) + ISNULL(g.[Dec],0) AS Q1,
        ISNULL(g.[Jan],0) + ISNULL(g.[Feb],0) + ISNULL(g.[Mar],0) AS Q2,
        ISNULL(g.[Apr],0) + ISNULL(g.[May],0) + ISNULL(g.[Jun],0) AS Q3,
        ISNULL(g.[Jul],0) + ISNULL(g.[Aug],0) + ISNULL(g.[Sep],0) AS Q4,
        ISNULL(g.[Oct],0) + ISNULL(g.[Nov],0) + ISNULL(g.[Dec],0)
          + ISNULL(g.[Jan],0) + ISNULL(g.[Feb],0) + ISNULL(g.[Mar],0)
          + ISNULL(g.[Apr],0) + ISNULL(g.[May],0) + ISNULL(g.[Jun],0)
          + ISNULL(g.[Jul],0) + ISNULL(g.[Aug],0) + ISNULL(g.[Sep],0) AS YTDTotal,
        ISNULL(e.Approved,   0) AS Approved,
        ISNULL(e.Routing,    0) AS Routing,
        ISNULL(a.Allocation, 0) AS Allocation
    FROM accountBase AS b
    -- Correction (e): layout-independent account-number splitter.
    --   {prefix}-{account}-{institution}-{responsibility}-{department}-{..}-{..}
    --   e.g. 4 - 80400 - H01 - 107 - 1157 - 00 - 000
    CROSS APPLY (SELECT NULLIF(CHARINDEX('-', b.AccountNumber), 0) AS d1) AS p1
    CROSS APPLY (SELECT NULLIF(CHARINDEX('-', b.AccountNumber, p1.d1 + 1), 0) AS d2) AS p2
    CROSS APPLY (SELECT NULLIF(CHARINDEX('-', b.AccountNumber, p2.d2 + 1), 0) AS d3) AS p3
    CROSS APPLY (SELECT NULLIF(CHARINDEX('-', b.AccountNumber, p3.d3 + 1), 0) AS d4) AS p4
    CROSS APPLY (SELECT NULLIF(CHARINDEX('-', b.AccountNumber, p4.d4 + 1), 0) AS d5) AS p5
    CROSS APPLY (
        SELECT
            LTRIM(RTRIM(SUBSTRING(b.AccountNumber, p1.d1 + 1, p2.d2 - p1.d1 - 1))) AS AccountSeg,
            LTRIM(RTRIM(SUBSTRING(b.AccountNumber, p2.d2 + 1, p3.d3 - p2.d2 - 1))) AS InstitutionSeg,
            LTRIM(RTRIM(SUBSTRING(b.AccountNumber, p3.d3 + 1, p4.d4 - p3.d3 - 1))) AS ResponsibilitySeg,
            LTRIM(RTRIM(SUBSTRING(b.AccountNumber, p4.d4 + 1, p5.d5 - p4.d4 - 1))) AS DepartmentSeg
    ) AS seg
    INNER JOIN varianceLines AS vl ON vl.AccountSeg     = seg.AccountSeg
    LEFT  JOIN glData         AS g ON g.AccountNumber   = b.AccountNumber
    LEFT  JOIN allocationData AS a ON a.AccountNumber   = b.AccountNumber
    LEFT  JOIN encumbranceData AS e ON e.AccountNumber  = b.AccountNumber
    -- Both LEFT, and that is load-bearing: a missing chart-of-accounts row must
    -- cost a LABEL, never a row and never money. Correction (b) is what keeps
    -- the allocation-only accounts (1,117 accounts / TTD 21.1M in FY2026) in
    -- the ledger, and an INNER join here would quietly undo it.
    --
    -- Note the join keys differ by design: coaData matches on the FULL account
    -- number, corrections on segment 2 (the account code) only - that is the
    -- grain the corrections table is keyed at.
    LEFT  JOIN coaData     AS c  ON c.AccountNumber = b.AccountNumber
    LEFT  JOIN corrections AS cr ON cr.AccountSeg   = seg.AccountSeg
    LEFT  JOIN deptSeg     AS dsg ON dsg.Seg = seg.DepartmentSeg
    LEFT  JOIN respSeg     AS rsg ON rsg.Seg = seg.ResponsibilitySeg
    LEFT  JOIN instSeg     AS isg ON isg.Seg = seg.InstitutionSeg
);
GO

/* ===========================================================================
   3. Snapshot tables
   ---------------------------------------------------------------------------
   Explicit DDL, not SELECT * INTO. Two reasons, both load-bearing:
     - SELECT * INTO would bake the source float types into the snapshot
       permanently, defeating correction (d);
     - INSERT ... SELECT * binds by POSITION, so a future column reorder would
       silently load money into a description column with no error. Every
       INSERT in this file therefore carries an explicit column list.

   Grain is (FinancialYear, AccountNumber) - user-agnostic. UserName is joined
   on live in vw_FinanceLedger, so permission changes need no refresh.
   =========================================================================== */
IF OBJECT_ID('dbo.FinanceLedgerSnapshot', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.FinanceLedgerSnapshot
    (
        FinancialYear      varchar(10)   NOT NULL,
        AccountNumber      varchar(255)  COLLATE Latin1_General_CI_AS NOT NULL,
        AccountDescription nvarchar(255) NULL,
        InstitutionID      varchar(50)   COLLATE Latin1_General_CI_AS NULL,
        ResponsibilityID   varchar(50)   COLLATE Latin1_General_CI_AS NULL,
        DepartmentID       varchar(50)   COLLATE Latin1_General_CI_AS NULL,
        ClusterName        nvarchar(255) NULL,
        InstitutionName    nvarchar(255) NULL,
        ResponsibilityName nvarchar(255) NULL,
        DepartmentName     nvarchar(255) NULL,
        LineNumber         float         NULL,
        LineDescription    varchar(255)  NULL,
        MainGroup          varchar(255)  NULL,
        SubGroupA          varchar(255)  NULL,
        SubGroupB          varchar(255)  NULL,
        [Oct] decimal(19,4) NOT NULL, [Nov] decimal(19,4) NOT NULL, [Dec] decimal(19,4) NOT NULL,
        [Jan] decimal(19,4) NOT NULL, [Feb] decimal(19,4) NOT NULL, [Mar] decimal(19,4) NOT NULL,
        [Apr] decimal(19,4) NOT NULL, [May] decimal(19,4) NOT NULL, [Jun] decimal(19,4) NOT NULL,
        [Jul] decimal(19,4) NOT NULL, [Aug] decimal(19,4) NOT NULL, [Sep] decimal(19,4) NOT NULL,
        Q1 decimal(19,4) NOT NULL, Q2 decimal(19,4) NOT NULL,
        Q3 decimal(19,4) NOT NULL, Q4 decimal(19,4) NOT NULL,
        YTDTotal   decimal(19,4) NOT NULL,
        Approved   decimal(19,4) NOT NULL,
        Routing    decimal(19,4) NOT NULL,
        Allocation decimal(19,4) NOT NULL
    );

    -- Leading FinancialYear because every app query filters on it; the access
    -- join then seeks on (ResponsibilityID, DepartmentID).
    CREATE CLUSTERED INDEX CIX_FinanceLedgerSnapshot
        ON dbo.FinanceLedgerSnapshot (FinancialYear, ResponsibilityID, DepartmentID, AccountNumber);
END
GO

IF OBJECT_ID('dbo.FinanceLedgerSnapshot_Staging', 'U') IS NULL
BEGIN
    SELECT TOP (0) *
    INTO dbo.FinanceLedgerSnapshot_Staging
    FROM dbo.FinanceLedgerSnapshot;

    CREATE CLUSTERED INDEX CIX_FinanceLedgerSnapshot_Staging
        ON dbo.FinanceLedgerSnapshot_Staging (FinancialYear, ResponsibilityID, DepartmentID, AccountNumber);
END
GO

/* Freshness + outcome metadata, one row per fiscal year. The app reads
   MAX(RefreshedAt) to version its filter caches. */
IF OBJECT_ID('dbo.FinanceLedgerRefresh', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.FinanceLedgerRefresh
    (
        FinancialYear   varchar(10)   NOT NULL PRIMARY KEY,
        RefreshedAt     datetime2(0)  NOT NULL,
        RowsLoaded      int           NOT NULL,
        DurationSeconds int           NOT NULL,
        TotalAllocation decimal(19,4) NOT NULL,
        TotalYTD        decimal(19,4) NOT NULL,
        Outcome         varchar(20)   NOT NULL,   -- OK | ABORTED
        Message         nvarchar(1000) NULL
    );
END
GO

/* Additive columns for the gates introduced with the Oversight update.
   Idempotent - safe to re-run. The app reads only MAX(RefreshedAt) and
   Outcome, so nothing downstream is affected by these. */
IF COL_LENGTH('dbo.FinanceLedgerRefresh', 'TotalApproved') IS NULL
    ALTER TABLE dbo.FinanceLedgerRefresh ADD TotalApproved decimal(19,4) NOT NULL CONSTRAINT DF_FLR_TotalApproved DEFAULT (0);
GO
IF COL_LENGTH('dbo.FinanceLedgerRefresh', 'TotalRouting') IS NULL
    ALTER TABLE dbo.FinanceLedgerRefresh ADD TotalRouting decimal(19,4) NOT NULL CONSTRAINT DF_FLR_TotalRouting DEFAULT (0);
GO
IF COL_LENGTH('dbo.FinanceLedgerRefresh', 'UndefinedLabelPct') IS NULL
    ALTER TABLE dbo.FinanceLedgerRefresh ADD UndefinedLabelPct decimal(5,2) NOT NULL CONSTRAINT DF_FLR_UndefLabelPct DEFAULT (0);
GO

/* ===========================================================================
   4. dbo.vw_FinanceLedger  -  DEFINED ELSEWHERE, DELIBERATELY
   ---------------------------------------------------------------------------
   Both dbo.vw_FinanceLedger and dbo.vw_WebAppUserAccess now live in
   sql/FinanceLedgerOversightCutover.sql, which applies them TOGETHER in one
   transaction behind a set of guards.

   They are not here because applying them from this script would be unsafe on
   a live system, in two ways:

     1. FAN-OUT. 0006CWebAppPostControls carries an InstitutionID, and 32 of
        128 active (Responsibility, Department) pairs appear twice, differing
        only by institution. The 4-tuple access view above emits two rows for
        those pairs. Any moment where it is live alongside a two-column ledger
        join - even the milliseconds between two GO batches - doubles every
        money figure on 25% of the mappings.

     2. NO GUARDS. The cutover refuses to run when InstitutionID is missing or
        blank, and verifies the result. There is deliberately no fallback to
        the old two-way join: that rule exposed TTD 99.1M of another
        institution's allocation, so an absent column must FAIL the release
        rather than silently reinstate the defect.

   RUN ORDER, fresh install or dev:
       1. this file
       2. EXEC dbo.usp_RefreshFinanceLedgerSnapshotAll
       3. sql/FinanceLedgerOversightCutover.sql
       4. sql/FinanceLedgerCutover.sql   (MonthlyExpenditure / vw_BudgetAllocation)

   RUN ORDER, live production: see the deployment section of
   financesqlupdate.md. Steps 1-2 are invisible to users - the function and
   procs feed only the refresh - so the app keeps serving the old rule while
   the snapshot rebuilds. Step 3 is the single user-visible moment.
   =========================================================================== */

/* ===========================================================================
   5. dbo.usp_RefreshFinanceLedgerSnapshot
   ---------------------------------------------------------------------------
   Builds one fiscal year into staging, applies the sanity gates, then swaps
   that year's slice into the live table in one short transaction.

   A refresh that ERRORS is already safe - it never reaches the swap. The
   dangerous case is one that SUCCEEDS against a degraded source (a linked
   server returning nothing, a half-loaded GL) and quietly writes a truncated
   result over good data. The gates below exist for that case: they abort,
   keep the previous snapshot, record the reason, and THROW so the caller sees
   a failure rather than a silent no-op.

   @Force bypasses the movement gates for a genuine large change - a new FY
   opening, a bulk reallocation. It never bypasses the zero-row gate.
   =========================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_RefreshFinanceLedgerSnapshot
    @FinancialYear  varchar(10),
    @Force          bit = 0,
    @MinRows        int = 1,
    @MaxDropPercent decimal(5,2) = 10.00,   -- row-count fall vs last good load
    @MaxMovePercent decimal(5,2) = 25.00,   -- money movement vs last good load
    @MaxUndefinedPercent decimal(5,2) = 2.00 -- share of rows with no department label
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @FinancialYear IS NULL OR TRY_CONVERT(int, @FinancialYear) IS NULL
        THROW 51000, 'usp_RefreshFinanceLedgerSnapshot: @FinancialYear must be a numeric year, e.g. ''2026''.', 1;

    DECLARE @startedAt datetime2(0) = SYSDATETIME();
    DECLARE @rows int, @alloc decimal(19,4), @ytd decimal(19,4);
    DECLARE @approved decimal(19,4), @routing decimal(19,4), @undefPct decimal(5,2);
    DECLARE @prevRows int, @prevAlloc decimal(19,4), @prevYtd decimal(19,4);
    DECLARE @prevApproved decimal(19,4);
    DECLARE @abort nvarchar(1000) = NULL;
    DECLARE @badRows int, @ambiguous int;

    /* ---- 4a. SOURCE GRAIN GUARDS -------------------------------------------
       Both of these would MULTIPLY money rather than merely mislabel it, so
       they abort before anything is built and are never bypassed by @Force.
       Measured 2026-08-25: both conditions are currently clean (9,463/9,463
       distinct accounts; 0 conflicting descriptions). */
    IF EXISTS (
        SELECT 1 FROM [FinanceAutomationSystem].[dbo].[0030ADGPCOA]
        GROUP BY UPPER(LTRIM(RTRIM(AccountNumber))) HAVING COUNT(*) > 1
    )
        THROW 51004, 'Refresh aborted: 0030ADGPCOA holds duplicate account numbers. The COA join would multiply every money column. Resolve the duplicate before refreshing.', 1;

    IF EXISTS (
        SELECT 1 FROM [FinanceAutomationSystem].[dbo].[0030AEAccountNameCorrections]
        GROUP BY UPPER(LTRIM(RTRIM(AccountNumber)))
        HAVING COUNT(DISTINCT UPPER(COALESCE(
                   NULLIF(LTRIM(RTRIM(EditedAccountDescription)), ''),
                   NULLIF(LTRIM(RTRIM(AccountDescription)),       '')))) > 1
    )
        THROW 51005, 'Refresh aborted: 0030AEAccountNameCorrections holds conflicting descriptions for one account segment. Clean the source or agree a deterministic tie-break with the finance team - do not let MIN() pick one silently.', 1;

    /* ---- 4d. SHIPMENT CONVERSION + KEY-AMBIGUITY GUARDS ---------------------
       fn_FinanceLedgerSource uses CONVERT (not TRY_CONVERT) on the varchar
       shipment columns, deliberately, so that bad data cannot be silently
       discarded into an understated shipment and an overstated commitment.
       These gates catch it first and give a usable message instead of a raw
       conversion error. NEVER bypassed by @Force: these are correctness
       failures, not legitimate financial movement. */
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
        THROW 51006, @bad, 1;
    END

    /* A duplicated (PONumber, POLineID) is two DISTINCT GP lines colliding on
       an insufficient key - POLNENUM tells them apart. Summing across them is
       wrong. 65 such keys exist and NONE currently intersects an open
       requisition; if one ever does, stop rather than guess. */
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
    WHERE e.Status IN ('AP','PO','RT','HD','PN')
      AND e.ReqDateCreated >= DATEFROMPARTS(CONVERT(int, @FinancialYear) - 1, 10, 1)
      AND e.ReqDateCreated <  DATEFROMPARTS(CONVERT(int, @FinancialYear),     10, 1);

    IF @ambiguous > 0
    BEGIN
        DECLARE @amb nvarchar(500) = N'Refresh aborted: '
            + CONVERT(nvarchar(20), @ambiguous)
            + N' open encumbrance line(s) for FY' + @FinancialYear
            + N' match a duplicated (PONumber, POLineID) shipment key. Those are different GP lines, '
            + N'so summing their shipments would corrupt the commitment. Establish the correct unique key '
            + N'(likely including POLNENUM) with finance/GP and update both sides of the join.';
        THROW 51007, @amb, 1;
    END

    /* ---- schema-drift guard ------------------------------------------------
       The snapshot and the function must agree on column names, or the
       explicit INSERT below starts writing the wrong values into the right
       columns. Compared by name, both directions. */
    IF EXISTS (
        SELECT name COLLATE Latin1_General_CI_AS FROM sys.dm_exec_describe_first_result_set
            (N'SELECT * FROM dbo.fn_FinanceLedgerSource(''2026'')', NULL, 0)
        EXCEPT
        SELECT name COLLATE Latin1_General_CI_AS FROM sys.columns WHERE object_id = OBJECT_ID('dbo.FinanceLedgerSnapshot')
    )
    OR EXISTS (
        SELECT name COLLATE Latin1_General_CI_AS FROM sys.columns WHERE object_id = OBJECT_ID('dbo.FinanceLedgerSnapshot')
        EXCEPT
        SELECT name COLLATE Latin1_General_CI_AS FROM sys.dm_exec_describe_first_result_set
            (N'SELECT * FROM dbo.fn_FinanceLedgerSource(''2026'')', NULL, 0)
    )
        THROW 51001, 'usp_RefreshFinanceLedgerSnapshot: column drift between fn_FinanceLedgerSource and FinanceLedgerSnapshot. Re-run sql/FinanceLedger.sql.', 1;

    /* ---- build into staging ---------------------------------------------- */
    DELETE FROM dbo.FinanceLedgerSnapshot_Staging WHERE FinancialYear = @FinancialYear;

    INSERT INTO dbo.FinanceLedgerSnapshot_Staging
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
    FROM dbo.fn_FinanceLedgerSource(@FinancialYear);

    SELECT
        @rows     = COUNT(*),
        @alloc    = ISNULL(SUM(Allocation), 0),
        @ytd      = ISNULL(SUM(YTDTotal), 0),
        @approved = ISNULL(SUM(Approved), 0),
        @routing  = ISNULL(SUM(Routing), 0),
        -- Measured on the STAGED result, not on the 9,463-row COA table: the
        -- reporting-line-3 filter and the account-base join mean the ledger
        -- sees a different population, so the COA-wide figure is the wrong
        -- baseline.
        @undefPct = CASE WHEN COUNT(*) = 0 THEN 0 ELSE
                        CONVERT(decimal(5,2),
                            100.0 * SUM(CASE WHEN DepartmentName = 'UNDEFINED' THEN 1 ELSE 0 END) / COUNT(*))
                    END
    FROM dbo.FinanceLedgerSnapshot_Staging
    WHERE FinancialYear = @FinancialYear;

    SELECT @prevRows = RowsLoaded, @prevAlloc = TotalAllocation, @prevYtd = TotalYTD,
           @prevApproved = TotalApproved
    FROM dbo.FinanceLedgerRefresh
    WHERE FinancialYear = @FinancialYear AND Outcome = 'OK';

    /* ---- sanity gates ----------------------------------------------------- */
    IF @rows = 0
        SET @abort = N'Staging is empty - the source returned no rows.';
    ELSE IF @rows < @MinRows
        SET @abort = N'Staging row count ' + CONVERT(nvarchar(20), @rows)
                   + N' is below the floor of ' + CONVERT(nvarchar(20), @MinRows) + N'.';

    IF @abort IS NULL AND @Force = 0 AND @prevRows IS NOT NULL AND @prevRows > 0
    BEGIN
        IF (100.0 * (@prevRows - @rows) / @prevRows) > @MaxDropPercent
            SET @abort = N'Row count fell from ' + CONVERT(nvarchar(20), @prevRows)
                       + N' to ' + CONVERT(nvarchar(20), @rows) + N'.';
        ELSE IF @prevAlloc <> 0 AND ABS(100.0 * (@alloc - @prevAlloc) / @prevAlloc) > @MaxMovePercent
            SET @abort = N'Total allocation moved from ' + CONVERT(nvarchar(40), @prevAlloc)
                       + N' to ' + CONVERT(nvarchar(40), @alloc) + N'.';
        ELSE IF @prevYtd <> 0 AND ABS(100.0 * (@ytd - @prevYtd) / @prevYtd) > @MaxMovePercent
            SET @abort = N'Total YTD moved from ' + CONVERT(nvarchar(40), @prevYtd)
                       + N' to ' + CONVERT(nvarchar(40), @ytd) + N'.';

        /* 4b. LABEL COVERAGE. If 0030ADGPCOA goes stale, is truncated or gets
           repointed, every name becomes 'UNDEFINED' while every FIGURE stays
           perfect - so no money gate would ever notice, and the page turns
           into a wall of UNDEFINED. Threshold is deliberately loose: the
           measured baseline is 0% NULL/blank across the COA, with 24 rows
           (0.25%) carrying REMOVE/UNDEFINED sentinels. Re-measure per year on
           first deployment and tighten if there is headroom. */
        ELSE IF @undefPct > @MaxUndefinedPercent
            SET @abort = N'Department labels are ' + CONVERT(nvarchar(20), @undefPct)
                       + N'% UNDEFINED, above the ' + CONVERT(nvarchar(20), @MaxUndefinedPercent)
                       + N'% ceiling. The chart-of-accounts mirror is probably stale or truncated.';

        /* 4c. ENCUMBRANCE ZERO-COLLAPSE. Deliberately NOT a percentage gate:
           netting off receipts is designed to move Approved, so a movement
           gate would abort every refresh from now on. This catches only the
           pathological case - the encumbrance or shipment table joining away
           entirely. */
        ELSE IF @prevApproved IS NOT NULL AND @prevApproved > 1000 AND @approved = 0
            SET @abort = N'Total Approved collapsed from ' + CONVERT(nvarchar(40), @prevApproved)
                       + N' to exactly zero. The encumbrance or shipment source probably failed to join.';
    END

    IF @abort IS NOT NULL
    BEGIN
        DELETE FROM dbo.FinanceLedgerSnapshot_Staging WHERE FinancialYear = @FinancialYear;

        -- Recorded as its own row state so a monitoring query can find it, but
        -- the last good load's figures are NOT overwritten.
        MERGE dbo.FinanceLedgerRefresh AS t
        USING (SELECT @FinancialYear AS FinancialYear) AS s ON t.FinancialYear = s.FinancialYear
        WHEN MATCHED THEN UPDATE SET Outcome = 'ABORTED', Message = @abort
        WHEN NOT MATCHED THEN INSERT (FinancialYear, RefreshedAt, RowsLoaded, DurationSeconds, TotalAllocation, TotalYTD, TotalApproved, TotalRouting, UndefinedLabelPct, Outcome, Message)
             VALUES (@FinancialYear, SYSDATETIME(), 0, 0, 0, 0, 0, 0, 0, 'ABORTED', @abort);

        DECLARE @msg nvarchar(1200) = N'Refresh aborted for FY' + @FinancialYear + N': ' + @abort
                                    + N' Previous snapshot retained. Re-run with @Force = 1 if this movement is genuine.';
        THROW 51002, @msg, 1;
    END

    /* ---- swap ------------------------------------------------------------- */
    BEGIN TRANSACTION;

        DELETE FROM dbo.FinanceLedgerSnapshot WHERE FinancialYear = @FinancialYear;

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
        FROM dbo.FinanceLedgerSnapshot_Staging
        WHERE FinancialYear = @FinancialYear;

        MERGE dbo.FinanceLedgerRefresh AS t
        USING (SELECT @FinancialYear AS FinancialYear) AS s ON t.FinancialYear = s.FinancialYear
        WHEN MATCHED THEN UPDATE SET
            RefreshedAt = SYSDATETIME(), RowsLoaded = @rows,
            DurationSeconds = DATEDIFF(second, @startedAt, SYSDATETIME()),
            TotalAllocation = @alloc, TotalYTD = @ytd,
            TotalApproved = @approved, TotalRouting = @routing, UndefinedLabelPct = @undefPct,
            Outcome = 'OK', Message = NULL
        WHEN NOT MATCHED THEN INSERT (FinancialYear, RefreshedAt, RowsLoaded, DurationSeconds, TotalAllocation, TotalYTD, TotalApproved, TotalRouting, UndefinedLabelPct, Outcome, Message)
             VALUES (@FinancialYear, SYSDATETIME(), @rows, DATEDIFF(second, @startedAt, SYSDATETIME()), @alloc, @ytd, @approved, @routing, @undefPct, 'OK', NULL);

    COMMIT TRANSACTION;

    DELETE FROM dbo.FinanceLedgerSnapshot_Staging WHERE FinancialYear = @FinancialYear;

    SELECT
        @FinancialYear AS FinancialYear,
        @rows          AS RowsLoaded,
        DATEDIFF(second, @startedAt, SYSDATETIME()) AS DurationSeconds,
        @alloc         AS TotalAllocation,
        @ytd           AS TotalYTD,
        @approved      AS TotalApproved,
        @routing       AS TotalRouting,
        @undefPct      AS UndefinedLabelPct;
END
GO

/* ===========================================================================
   6. dbo.usp_RefreshFinanceLedgerSnapshotAll
   ---------------------------------------------------------------------------
   Loops the fiscal years present in the source. Year-at-a-time is what makes
   the pushdown structural rather than hopeful: every call carries a sargable
   FinancialYear = @FY inside the CTEs. It also makes incremental refresh fall
   out for free - closed years never change, so schedule the current and prior
   FY often and the full loop rarely.

   @FromYear lets the scheduler refresh only recent years.
   A failing year is logged and the loop continues, so one bad year cannot
   block the rest; the proc THROWs at the end if any year failed.
   =========================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_RefreshFinanceLedgerSnapshotAll
    @FromYear varchar(10) = NULL,
    @Force    bit = 0
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @years TABLE (FinancialYear varchar(10) PRIMARY KEY);

    INSERT INTO @years (FinancialYear)
    SELECT DISTINCT FinancialYear
    FROM [FinanceAutomationSystem].[dbo].[0098AFinGLMaster]
    WHERE FinancialYear IS NOT NULL
      AND TRY_CONVERT(int, FinancialYear) IS NOT NULL
      AND (@FromYear IS NULL OR TRY_CONVERT(int, FinancialYear) >= TRY_CONVERT(int, @FromYear))
    UNION
    SELECT DISTINCT FinancialYear
    FROM [FinanceAutomationSystem].[dbo].[0040CBudgetsAllocation]
    WHERE FinancialYear IS NOT NULL
      AND TRY_CONVERT(int, FinancialYear) IS NOT NULL
      AND (@FromYear IS NULL OR TRY_CONVERT(int, FinancialYear) >= TRY_CONVERT(int, @FromYear));

    DECLARE @fy varchar(10), @failed int = 0;
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT FinancialYear FROM @years ORDER BY FinancialYear;

    OPEN c;
    FETCH NEXT FROM c INTO @fy;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        BEGIN TRY
            EXEC dbo.usp_RefreshFinanceLedgerSnapshot @FinancialYear = @fy, @Force = @Force;
        END TRY
        BEGIN CATCH
            SET @failed = @failed + 1;
            PRINT 'FY' + @fy + ' FAILED: ' + ERROR_MESSAGE();
        END CATCH

        FETCH NEXT FROM c INTO @fy;
    END

    CLOSE c;
    DEALLOCATE c;

    IF @failed > 0
    BEGIN
        DECLARE @m nvarchar(200) = N'usp_RefreshFinanceLedgerSnapshotAll: '
            + CONVERT(nvarchar(10), @failed) + N' fiscal year(s) failed. See dbo.FinanceLedgerRefresh.';
        THROW 51003, @m, 1;
    END
END
GO

/* ===========================================================================
   OPTIONAL INDEX - NOT RECOMMENDED. Measured; it would buy ~1 second.
   ---------------------------------------------------------------------------
   An earlier version of this comment claimed the 6,377,713-row scan of
   0098AFinGLMaster was the dominant cost of the build, and that this index was
   the fix. BOTH CLAIMS ARE WRONG. Measured on production (sqlapp\SQLEXPRESS):

     COUNT(*) with no filter ................................. 0.95s
     COUNT(*) WHERE FinancialYear = '2026' ................... 0.95s  (identical)
     Full glData aggregate for one FY (4,450 accounts) ....... 0.84s
     allocationData / encumbranceData / varianceLines ........ 0.02 / 0.03 / 0.01s
     FULL build for one fiscal year .................... 74 - 175s

   The FY filter is a scan rather than a seek, exactly as the missing index
   implies - but it does not matter, because the entire GL side is about one
   second. Roughly 72+ seconds of the build is in the account-base UNION, the
   CROSS APPLY splitter and the join chain, NOT in reading the fact tables.

   So this index would remove ~1s from a 74-175s build. It is not worth
   changing a source table this application does not own. DO NOT apply it on
   the strength of the old comment; profile the join/assembly phase instead.

     -- CREATE NONCLUSTERED INDEX IX_0098AFinGLMaster_FinancialYear
     --     ON dbo.[0098AFinGLMaster] (FinancialYear)
     --     INCLUDE (TRXDate, AccountNumber, AccountDescription, NetChange);
   =========================================================================== */
