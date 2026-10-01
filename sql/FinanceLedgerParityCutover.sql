/* ===========================================================================
   FinanceLedgerParityCutover.sql
   ---------------------------------------------------------------------------
   Swaps the ledger from the CORRECTED derivation to ACCESS PARITY.

   After this runs, the portal reproduces the finance department's Access query
   exactly on money and row grain - including behaviours the previous version
   deliberately corrected. Design: financeupdatesep.md. Status and the measured
   evidence: financeupdatesepprogress.md.

   WHAT CHANGES, AND WHAT THE USER WILL SEE
     - Encumbrance is NO LONGER FLOORED AT ZERO. An over-received line carries a
       NEGATIVE commitment. Measured FY2026: 694 lines / 62 accounts / -17.36M.
     - An account may occupy MORE THAN ONE ROW, where the GL master and the COA
       corrections spell its description differently. 24 accounts across
       FY2014-FY2026; FY2026 = 11.
     - AccountDescription for GL-sourced rows is now GL master's own spelling,
       not the curated correction.
     - YTDTotal does NOT move, in any year.
     - Allocation moves in ONE year only: FY2026, by +0.17 (one account the Access
       query drops).
     - Routing moves in TWO years: FY2024 by -107,341.68 and FY2025 by -0.01.
       An earlier draft of this header said Routing never moves - that is true of
       FY2026 only. Measured 2026-09-30.
     - FY2017 and FY2018 TotalApproved go NEGATIVE at the whole-year level
       (-3,974,133.73 and -1,444,587.97): those years hold more over-received
       value than open commitment. Access reports the same. Gate 4c does not fire,
       because it catches @approved = 0 exactly, not a negative.

   ROLLBACK is deliberately trivial: re-run sql/FinanceLedger.sql (idempotent
   CREATE OR ALTER, and it still holds the pre-parity definitions), then rebuild.

   RUN ORDER
     1. this script
     2. EXEC dbo.usp_RefreshFinanceLedgerSnapshot @FinancialYear = '2026'   <- GATE 2
     3. sql/ParityReconciliation.sql  (must report PASS)
     4. sql/FinanceRequisitionParityCutover.sql                             <- lockstep
     5. EXEC dbo.usp_RefreshFinanceRequisition @Force = 1                   <- GATE 3
     6. EXEC dbo.usp_RefreshFinanceLedgerSnapshotAll @Force = 1             <- all years

   Step 4 is NOT optional. Gate F in FinanceRequisition.sql reconciles the
   requisition detail to this snapshot's Approved/Routing and is never bypassed
   by @Force, so a ledger-only change freezes Phase 2 every night.
   =========================================================================== */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

USE FinanceAutomationSystem;
GO

/* ===========================================================================
   1. Schema additions - TABLES BEFORE THE FUNCTION.

   The schema-drift guard compares the function's result set against the
   snapshot's columns in BOTH directions and THROWs 51001 on any difference.
   Adding AccountID to the function first would abort the very next refresh.
   Idempotent, so re-running is safe.

   AccountID is int to match the draft: 0098AFinGLMaster.AccountID is
   nvarchar(255) and 0030ADGPCOA.AccountLineID is int, and in the draft's
   UNION ALL int WINS datatype precedence - so the Access column is an int and
   GL's strings are implicitly converted. The drift guard compares NAMES only,
   so the type is stated explicitly rather than left to precedence.
   =========================================================================== */
IF COL_LENGTH('dbo.FinanceLedgerSnapshot', 'AccountID') IS NULL
    ALTER TABLE dbo.FinanceLedgerSnapshot ADD AccountID int NULL;
GO
IF COL_LENGTH('dbo.FinanceLedgerSnapshot_Staging', 'AccountID') IS NULL
    ALTER TABLE dbo.FinanceLedgerSnapshot_Staging ADD AccountID int NULL;
GO

/* Grain telemetry. AccountsLoaded is DISTINCT accounts, which no longer equals
   RowsLoaded now that accounts can split - the gap between them IS the split
   count, and both are recorded so monitoring need not re-derive it. */
IF COL_LENGTH('dbo.FinanceLedgerRefresh', 'AccountsLoaded') IS NULL
    ALTER TABLE dbo.FinanceLedgerRefresh ADD AccountsLoaded int NULL;
GO
IF COL_LENGTH('dbo.FinanceLedgerRefresh', 'SplitAccountCount') IS NULL
    ALTER TABLE dbo.FinanceLedgerRefresh ADD SplitAccountCount int NULL;
GO

/* ===========================================================================
   2. dbo.fn_FinanceLedgerSource - the parity body.

   Identical to dbo.fn_FinanceLedgerAccessParity, which sql/ParityReconciliation.sql
   proved byte-identical to the Access query for every FY2014-FY2026: 0
   differences either direction, 0 multiplicity differences, split counts
   matching year for year. Keep that scratch function until Finance signs off -
   it is the only thing that can re-prove this in place.

   The rationale for every deviation - six of them, all measured free - is in
   the header of sql/FinanceLedgerAccessParity.sql. Read it before editing.
   =========================================================================== */
CREATE OR ALTER FUNCTION dbo.fn_FinanceLedgerSource
(
    @FinancialYear varchar(10)
)
RETURNS TABLE
AS
RETURN
(
    WITH
    /* =======================================================================
       GRAIN SIDE - the draft's coaData, semantics preserved exactly.

       NOTE the description source: it is NOT 0030ADGPCOA.AccountDescription.
       The draft takes it from 0030AEAccountNameCorrections via
       COALESCE(EditedAccountDescription, AccountDescription), joined on
       AccountSegment2, WITH NO FALLBACK - so an account whose segment has no
       correction row gets a NULL description on the allocation and encumbrance
       branches while the GL branch keeps GL master's own spelling. THAT
       DIVERGENCE IS THE SPLIT. Measured FY2026: differs on 43 accounts, 7 of
       which carry both GL and allocation activity.

       The SELECT DISTINCT is the draft's, not a GROUP BY + MIN. It collapses
       losslessly only while no account segment carries two different final
       descriptions (measured: 0). Gate 4a's THROW 51005 is what keeps that
       true, and it now guards THREE joins to this CTE rather than one.
       ======================================================================= */
    draftCorr AS (
        SELECT DISTINCT
            AccountNumber,
            COALESCE(EditedAccountDescription, AccountDescription) AS FinalAccountDescriptionVersion
        FROM [FinanceAutomationSystem].[dbo].[0030AEAccountNameCorrections]
    ),
    draftCoa AS (
        SELECT
            A.AccountLineID,
            A.AccountSegment2,
            A.AccountSegment3,
            A.AccountSegment4,
            A.AccountSegment5,
            A.AccountNumber,
            B.FinalAccountDescriptionVersion AS AccountDescription
        FROM [FinanceAutomationSystem].[dbo].[0030ADGPCOA] AS A
        LEFT JOIN draftCorr AS B
               ON A.AccountSegment2 = B.AccountNumber
    ),

    /* =======================================================================
       LABEL SIDE - kept from the deployed function. Names only; no money, no
       grain. Sentinels are normalised to NULL here so that the single
       ISNULL(..., 'UNDEFINED') in the final projection is the one place a
       missing label gets named.
       ======================================================================= */
    coaLabels AS (
        SELECT
            UPPER(LTRIM(RTRIM(c.AccountNumber))) COLLATE Latin1_General_CI_AS AS AccountNumber,
            NULLIF(NULLIF(NULLIF(LTRIM(RTRIM(c.Cluster)),            ''), 'REMOVE'), 'UNDEFINED') AS ClusterName,
            NULLIF(NULLIF(NULLIF(LTRIM(RTRIM(c.InstitutionName)),    ''), 'REMOVE'), 'UNDEFINED') AS InstitutionName,
            NULLIF(NULLIF(NULLIF(LTRIM(RTRIM(c.ResponsibilityName)), ''), 'REMOVE'), 'UNDEFINED') AS ResponsibilityName,
            NULLIF(NULLIF(NULLIF(LTRIM(RTRIM(c.DepartmentName)),     ''), 'REMOVE'), 'UNDEFINED') AS DepartmentName
        FROM [FinanceAutomationSystem].[dbo].[0030ADGPCOA] AS c
    ),
    deptSeg AS (
        SELECT UPPER(LTRIM(RTRIM(AccountSegment5))) COLLATE Latin1_General_CI_AS AS Seg,
               MIN(NULLIF(NULLIF(NULLIF(LTRIM(RTRIM(DepartmentName)), ''), 'REMOVE'), 'UNDEFINED')) AS Name
        FROM [FinanceAutomationSystem].[dbo].[0030ADGPCOA]
        GROUP BY UPPER(LTRIM(RTRIM(AccountSegment5)))
    ),
    respSeg AS (
        SELECT UPPER(LTRIM(RTRIM(AccountSegment4))) COLLATE Latin1_General_CI_AS AS Seg,
               MIN(NULLIF(NULLIF(NULLIF(LTRIM(RTRIM(ResponsibilityName)), ''), 'REMOVE'), 'UNDEFINED')) AS Name
        FROM [FinanceAutomationSystem].[dbo].[0030ADGPCOA]
        GROUP BY UPPER(LTRIM(RTRIM(AccountSegment4)))
    ),
    instSeg AS (
        SELECT UPPER(LTRIM(RTRIM(AccountSegment3))) COLLATE Latin1_General_CI_AS AS Seg,
               MIN(NULLIF(NULLIF(NULLIF(LTRIM(RTRIM(InstitutionName)), ''), 'REMOVE'), 'UNDEFINED')) AS Name,
               MIN(NULLIF(NULLIF(NULLIF(LTRIM(RTRIM(Cluster)),         ''), 'REMOVE'), 'UNDEFINED')) AS ClusterName
        FROM [FinanceAutomationSystem].[dbo].[0030ADGPCOA]
        GROUP BY UPPER(LTRIM(RTRIM(AccountSegment3)))
    ),

    /* Reporting line 3 - the 41-account goods-and-services scope. Payroll is
       excluded BY DESIGN; see CLAUDE.md. Joined INNER on AccountN, which is a
       per-branch grain column, so a branch whose AccountN does not match is
       dropped - exactly as the draft drops it. */
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

    /* =======================================================================
       ENCUMBRANCE - the draft's arithmetic, deliberately UNFLOORED.

       ActCost = ROUND((Quantity - QtyShipped) * UnitCost, 2), in float, with
       NO zero floor. An over-shipped line therefore contributes a NEGATIVE
       commitment, which is what Access reports and what Finance reconciles to.
       Measured FY2026: 694 such lines across 62 accounts, -17,363,584.00 raw.

       Shipments stay pre-aggregated (see header note 4).

       The draft computes Approved as ROUND(ISNULL(AP,0) + ISNULL(PO,0), 2)
       over the RAW pivot sums - not over the separately rounded AP and PO.
       Reproduced exactly.
       ======================================================================= */
    encShipped AS (
        SELECT
            PONumber,
            CONVERT(int, POLineID) AS POLineID,
            SUM(CONVERT(decimal(19,4), QTYShipped)) AS QtyShipped
        FROM [FinanceAutomationSystem].[dbo].[0098FPOShipmentDetails]
        GROUP BY PONumber, CONVERT(int, POLineID)
    ),
    encLines AS (
        SELECT
            e.GLAccount,
            e.Status,
            ROUND(((e.Quantity - ISNULL(s.QtyShipped, 0)) * e.UnitCost), 2) AS ActCost
        FROM [FinanceAutomationSystem].[dbo].[0040DBudgetsEncumbrance] AS e
        LEFT JOIN encShipped AS s
               ON s.PONumber = e.PONumber
              AND s.POLineID = e.LineNbr
        WHERE e.Status IN ('AP','PO','RT','HD','PN')
          AND e.ReqDateCreated >= DATEFROMPARTS(CONVERT(int, @FinancialYear) - 1, 10, 1)
          AND e.ReqDateCreated <  DATEFROMPARTS(CONVERT(int, @FinancialYear),     10, 1)
    ),
    encumberanceData AS (
        SELECT
            GLAccount,
            ROUND(ISNULL(SUM(CASE WHEN Status = 'AP' THEN ActCost END), 0)
                + ISNULL(SUM(CASE WHEN Status = 'PO' THEN ActCost END), 0), 2) AS Approved,
            ROUND(ISNULL(SUM(CASE WHEN Status = 'RT' THEN ActCost END), 0)
                + ISNULL(SUM(CASE WHEN Status = 'HD' THEN ActCost END), 0)
                + ISNULL(SUM(CASE WHEN Status = 'PN' THEN ActCost END), 0), 2) AS Routing
        FROM encLines
        GROUP BY GLAccount
    ),

    /* Allocation - grouped exactly as the draft groups it. */
    allocationData AS (
        SELECT
            FinancialYear,
            AccountNumber,
            ROUND(SUM(Allocation), 2) AS Allocation
        FROM [FinanceAutomationSystem].[dbo].[0040CBudgetsAllocation]
        WHERE FinancialYear = @FinancialYear
        GROUP BY FinancialYear, AccountNumber
    ),

    /* =======================================================================
       THE TALL UNION - three branches, each with its OWN derivation of the
       eight grain columns. The draft is internally inconsistent here (COA
       segments for allocation, fixed byte offsets for GL and encumbrance) and
       that inconsistency is load-bearing: it is a second split driver on the
       account numbers that are 26 characters rather than 27.
       ======================================================================= */
    allConsolidated AS (
        /* --- GL: segments by byte offset, identity from GL master ---------- */
        SELECT
            CONVERT(varchar(10), g.FinancialYear)                AS FinancialYear,
            CONVERT(int, g.AccountID)                            AS AccountID,
            CONVERT(varchar(255), g.AccountNumber)               AS AccountNumber,
            CONVERT(nvarchar(255), g.AccountDescription)          AS AccountDescription,
            CONVERT(varchar(50), substring(g.AccountNumber,  3, 5)) AS AccountN,
            CONVERT(varchar(50), substring(g.AccountNumber,  9, 3)) AS InstitutionID,
            CONVERT(varchar(50), substring(g.AccountNumber, 13, 3)) AS ResponsibilityID,
            CONVERT(varchar(50), substring(g.AccountNumber, 17, 4)) AS DepartmentID,
            CONVERT(varchar(10), MONTH(g.TRXDate))               AS Measure,
            g.NetChange                                          AS Amount
        FROM [FinanceAutomationSystem].[dbo].[0098AFinGLMaster] AS g
        WHERE g.FinancialYear = @FinancialYear
          AND g.NetChange <> 0

        UNION ALL

        /* --- Allocation: segments and identity from the COA ---------------- */
        SELECT
            CONVERT(varchar(10), a.FinancialYear)                AS FinancialYear,
            CONVERT(int, b.AccountLineID)                        AS AccountID,
            CONVERT(varchar(255), a.AccountNumber)               AS AccountNumber,
            CONVERT(nvarchar(255), b.AccountDescription)          AS AccountDescription,
            CONVERT(varchar(50), b.AccountSegment2)              AS AccountN,
            CONVERT(varchar(50), b.AccountSegment3)              AS InstitutionID,
            CONVERT(varchar(50), b.AccountSegment4)              AS ResponsibilityID,
            CONVERT(varchar(50), b.AccountSegment5)              AS DepartmentID,
            'Allocation'                                         AS Measure,
            a.Allocation                                         AS Amount
        FROM allocationData AS a
        LEFT JOIN draftCoa AS b
               ON a.AccountNumber = b.AccountNumber
        WHERE a.Allocation <> 0

        UNION ALL

        /* --- Encumbrance: segments by byte offset, identity from the COA.
               UNPIVOT (Approved, Routing) reproduced as two UNION ALL legs. -- */
        SELECT
            CONVERT(varchar(10), @FinancialYear)                 AS FinancialYear,
            CONVERT(int, b.AccountLineID)                        AS AccountID,
            CONVERT(varchar(255), e.GLAccount)                   AS AccountNumber,
            CONVERT(nvarchar(255), b.AccountDescription)          AS AccountDescription,
            CONVERT(varchar(50), substring(e.GLAccount,  3, 5))  AS AccountN,
            CONVERT(varchar(50), substring(e.GLAccount,  9, 3))  AS InstitutionID,
            CONVERT(varchar(50), substring(e.GLAccount, 13, 3))  AS ResponsibilityID,
            CONVERT(varchar(50), substring(e.GLAccount, 17, 4))  AS DepartmentID,
            'Approved'                                           AS Measure,
            e.Approved                                           AS Amount
        FROM encumberanceData AS e
        LEFT JOIN draftCoa AS b
               ON e.GLAccount = b.AccountNumber
        WHERE e.Approved <> 0

        UNION ALL

        SELECT
            CONVERT(varchar(10), @FinancialYear)                 AS FinancialYear,
            CONVERT(int, b.AccountLineID)                        AS AccountID,
            CONVERT(varchar(255), e.GLAccount)                   AS AccountNumber,
            CONVERT(nvarchar(255), b.AccountDescription)          AS AccountDescription,
            CONVERT(varchar(50), substring(e.GLAccount,  3, 5))  AS AccountN,
            CONVERT(varchar(50), substring(e.GLAccount,  9, 3))  AS InstitutionID,
            CONVERT(varchar(50), substring(e.GLAccount, 13, 3))  AS ResponsibilityID,
            CONVERT(varchar(50), substring(e.GLAccount, 17, 4))  AS DepartmentID,
            'Routing'                                            AS Measure,
            e.Routing                                            AS Amount
        FROM encumberanceData AS e
        LEFT JOIN draftCoa AS b
               ON e.GLAccount = b.AccountNumber
        WHERE e.Routing <> 0
    ),

    /* =======================================================================
       THE GRAIN. This eight-column GROUP BY *is* the specification of the row
       grain, and it is the whole subject of financeupdatesep.md. Adding or
       removing a column here changes how many rows an account occupies and
       therefore whether the portal agrees with Access.
       ======================================================================= */
    grouped AS (
        SELECT
            FinancialYear, AccountID, AccountNumber, AccountDescription,
            AccountN, InstitutionID, ResponsibilityID, DepartmentID,
            SUM(CASE WHEN Measure = '10'         THEN Amount END) AS [Oct],
            SUM(CASE WHEN Measure = '11'         THEN Amount END) AS [Nov],
            SUM(CASE WHEN Measure = '12'         THEN Amount END) AS [Dec],
            SUM(CASE WHEN Measure = '1'          THEN Amount END) AS [Jan],
            SUM(CASE WHEN Measure = '2'          THEN Amount END) AS [Feb],
            SUM(CASE WHEN Measure = '3'          THEN Amount END) AS [Mar],
            SUM(CASE WHEN Measure = '4'          THEN Amount END) AS [Apr],
            SUM(CASE WHEN Measure = '5'          THEN Amount END) AS [May],
            SUM(CASE WHEN Measure = '6'          THEN Amount END) AS [Jun],
            SUM(CASE WHEN Measure = '7'          THEN Amount END) AS [Jul],
            SUM(CASE WHEN Measure = '8'          THEN Amount END) AS [Aug],
            SUM(CASE WHEN Measure = '9'          THEN Amount END) AS [Sep],
            SUM(CASE WHEN Measure = 'Allocation' THEN Amount END) AS Allocation,
            SUM(CASE WHEN Measure = 'Approved'   THEN Amount END) AS Approved,
            SUM(CASE WHEN Measure = 'Routing'    THEN Amount END) AS Routing
        FROM allConsolidated
        GROUP BY
            FinancialYear, AccountID, AccountNumber, AccountDescription,
            AccountN, InstitutionID, ResponsibilityID, DepartmentID
    )

    /* =======================================================================
       FINAL PROJECTION - the snapshot's column list, plus AccountID.

       Money is rounded to 2dp exactly where the draft rounds, then CONVERTed
       to decimal(19,4) so the stored column types are untouched. Converting a
       value that has just been ROUNDed to 2dp is exact at these magnitudes, so
       this yields byte parity AND a stable type.
       ======================================================================= */
    SELECT
        p.FinancialYear,
        p.AccountID,
        p.AccountNumber,
        p.AccountDescription,
        p.InstitutionID,
        p.ResponsibilityID,
        p.DepartmentID,
        /* Label chain: full-account label -> segment-level label -> 'UNDEFINED'.
           Keyed on the account NUMBER via the layout-independent splitter, not
           on the draft's per-branch segments - labels are not grain. */
        CONVERT(nvarchar(255), COALESCE(cl.ClusterName,        isg.ClusterName, 'UNDEFINED')) AS ClusterName,
        CONVERT(nvarchar(255), COALESCE(cl.InstitutionName,    isg.Name,        'UNDEFINED')) AS InstitutionName,
        CONVERT(nvarchar(255), COALESCE(cl.ResponsibilityName, rsg.Name,        'UNDEFINED')) AS ResponsibilityName,
        CONVERT(nvarchar(255), COALESCE(cl.DepartmentName,     dsg.Name,        'UNDEFINED')) AS DepartmentName,
        vl.LineNumber,
        CONVERT(varchar(255), vl.LineDescription) AS LineDescription,
        CONVERT(varchar(255), vl.MainGroup)       AS MainGroup,
        CONVERT(varchar(255), vl.SubGroupA)       AS SubGroupA,
        CONVERT(varchar(255), vl.SubGroupB)       AS SubGroupB,
        CONVERT(decimal(19,4), ROUND(ISNULL(p.[Oct], 0), 2)) AS [Oct],
        CONVERT(decimal(19,4), ROUND(ISNULL(p.[Nov], 0), 2)) AS [Nov],
        CONVERT(decimal(19,4), ROUND(ISNULL(p.[Dec], 0), 2)) AS [Dec],
        CONVERT(decimal(19,4), ROUND(ISNULL(p.[Jan], 0), 2)) AS [Jan],
        CONVERT(decimal(19,4), ROUND(ISNULL(p.[Feb], 0), 2)) AS [Feb],
        CONVERT(decimal(19,4), ROUND(ISNULL(p.[Mar], 0), 2)) AS [Mar],
        CONVERT(decimal(19,4), ROUND(ISNULL(p.[Apr], 0), 2)) AS [Apr],
        CONVERT(decimal(19,4), ROUND(ISNULL(p.[May], 0), 2)) AS [May],
        CONVERT(decimal(19,4), ROUND(ISNULL(p.[Jun], 0), 2)) AS [Jun],
        CONVERT(decimal(19,4), ROUND(ISNULL(p.[Jul], 0), 2)) AS [Jul],
        CONVERT(decimal(19,4), ROUND(ISNULL(p.[Aug], 0), 2)) AS [Aug],
        CONVERT(decimal(19,4), ROUND(ISNULL(p.[Sep], 0), 2)) AS [Sep],
        CONVERT(decimal(19,4), ROUND(ISNULL(p.[Oct],0) + ISNULL(p.[Nov],0) + ISNULL(p.[Dec],0), 2)) AS Q1,
        CONVERT(decimal(19,4), ROUND(ISNULL(p.[Jan],0) + ISNULL(p.[Feb],0) + ISNULL(p.[Mar],0), 2)) AS Q2,
        CONVERT(decimal(19,4), ROUND(ISNULL(p.[Apr],0) + ISNULL(p.[May],0) + ISNULL(p.[Jun],0), 2)) AS Q3,
        CONVERT(decimal(19,4), ROUND(ISNULL(p.[Jul],0) + ISNULL(p.[Aug],0) + ISNULL(p.[Sep],0), 2)) AS Q4,
        CONVERT(decimal(19,4), ROUND(
              ISNULL(p.[Oct],0) + ISNULL(p.[Nov],0) + ISNULL(p.[Dec],0)
            + ISNULL(p.[Jan],0) + ISNULL(p.[Feb],0) + ISNULL(p.[Mar],0)
            + ISNULL(p.[Apr],0) + ISNULL(p.[May],0) + ISNULL(p.[Jun],0)
            + ISNULL(p.[Jul],0) + ISNULL(p.[Aug],0) + ISNULL(p.[Sep],0), 2)) AS YTDTotal,
        CONVERT(decimal(19,4), ROUND(ISNULL(p.Approved,   0), 2)) AS Approved,
        CONVERT(decimal(19,4), ROUND(ISNULL(p.Routing,    0), 2)) AS Routing,
        CONVERT(decimal(19,4), ROUND(ISNULL(p.Allocation, 0), 2)) AS Allocation
    FROM grouped AS p
    /* Layout-independent splitter, for LABEL LOOKUP ONLY. The grain segments
       above come from the draft's per-branch expressions; these come from the
       account number, so a 26-character account still resolves its labels.
       TWO SPLITTERS IN ONE FUNCTION IS DELIBERATE - see the header. */
    CROSS APPLY (SELECT NULLIF(CHARINDEX('-', p.AccountNumber), 0) AS d1) AS p1
    CROSS APPLY (SELECT NULLIF(CHARINDEX('-', p.AccountNumber, p1.d1 + 1), 0) AS d2) AS p2
    CROSS APPLY (SELECT NULLIF(CHARINDEX('-', p.AccountNumber, p2.d2 + 1), 0) AS d3) AS p3
    CROSS APPLY (SELECT NULLIF(CHARINDEX('-', p.AccountNumber, p3.d3 + 1), 0) AS d4) AS p4
    CROSS APPLY (SELECT NULLIF(CHARINDEX('-', p.AccountNumber, p4.d4 + 1), 0) AS d5) AS p5
    CROSS APPLY (
        SELECT
            LTRIM(RTRIM(SUBSTRING(p.AccountNumber, p2.d2 + 1, p3.d3 - p2.d2 - 1))) AS InstitutionSeg,
            LTRIM(RTRIM(SUBSTRING(p.AccountNumber, p3.d3 + 1, p4.d4 - p3.d3 - 1))) AS ResponsibilitySeg,
            LTRIM(RTRIM(SUBSTRING(p.AccountNumber, p4.d4 + 1, p5.d5 - p4.d4 - 1))) AS DepartmentSeg
    ) AS lseg
    /* INNER, and grain-affecting: this is the goods-and-services scope, joined
       on the PER-BRANCH AccountN exactly as the draft joins it. */
    INNER JOIN varianceLines AS vl
            ON vl.AccountSeg = CONVERT(varchar(50), p.AccountN) COLLATE Latin1_General_CI_AS
    LEFT JOIN coaLabels AS cl
           ON cl.AccountNumber = UPPER(LTRIM(RTRIM(p.AccountNumber))) COLLATE Latin1_General_CI_AS
    LEFT JOIN deptSeg AS dsg ON dsg.Seg = UPPER(lseg.DepartmentSeg)     COLLATE Latin1_General_CI_AS
    LEFT JOIN respSeg AS rsg ON rsg.Seg = UPPER(lseg.ResponsibilitySeg) COLLATE Latin1_General_CI_AS
    LEFT JOIN instSeg AS isg ON isg.Seg = UPPER(lseg.InstitutionSeg)    COLLATE Latin1_General_CI_AS
);
GO

/* ===========================================================================
   3. dbo.usp_RefreshFinanceLedgerSnapshot - gates updated for the new grain.

   CHANGES vs sql/FinanceLedger.sql:
     - AccountID added to both the staging and the promotion column lists.
     - Gate 4e (51007, duplicated shipment key) WIDENED from @FinancialYear to
       all years. NOT downgraded: removing the zero floor makes an ambiguous key
       visible money for the first time, so the tripwire matters more now.
     - NEW 51008: a TRUE fan-out - two staging rows identical across the whole
       stored grain. Replaces the retired "two rows per account = doubling"
       assumption, which the Access split legitimately breaks.
     - NEW 51009 / @MaxSplitAccounts: a ceiling on how many accounts may split.
       NOT bypassed by @Force, because the all-years rebuild runs @Force = 1 and
       this must still hold.
     - AccountsLoaded / SplitAccountCount recorded on every outcome.
   =========================================================================== */
CREATE OR ALTER PROCEDURE dbo.usp_RefreshFinanceLedgerSnapshot
    @FinancialYear  varchar(10),
    @Force          bit = 0,
    @MinRows        int = 1,
    @MaxDropPercent decimal(5,2) = 10.00,   -- row-count fall vs last good load
    @MaxMovePercent decimal(5,2) = 25.00,   -- money movement vs last good load
    @MaxUndefinedPercent decimal(5,2) = 2.00 -- share of rows with no department label
    -- Accounts legitimately occupying MORE THAN ONE row, because the Access
    -- query's grain splits them where the GL master and the COA corrections
    -- spell the description differently. Baselined from a measured rebuild
    -- (financeupdatesepprogress.md): 24 across FY2014-FY2026, FY2026 = 11.
    -- A jump means a NEW split driver, which is a stop, not a curiosity.
   ,@MaxSplitAccounts int = 40
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
    DECLARE @splitAccounts int, @fanout int, @distinctAccounts int;
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
      /* WIDENED 2026-09-29 (Access parity). This gate used to be bounded to
         @FinancialYear. It is now all-years, because (a) the parity release
         rebuilds every year, and (b) removing the zero floor UNMASKS this bug
         class: previously an over-shipped line clamped to 0 under BOTH the
         pre-aggregated and the fan-out treatment, so an ambiguous key was
         invisible - now it is visible money. Measured 2026-09-29: ZERO open
         lines match a duplicated key in ANY year, so this fires on nothing
         today and is purely a tripwire. */;

    IF @ambiguous > 0
    BEGIN
        DECLARE @amb nvarchar(500) = N'Refresh aborted: '
            + CONVERT(nvarchar(20), @ambiguous)
            + N' open encumbrance line(s) (ANY fiscal year)'
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
        FinancialYear, AccountID, AccountNumber, AccountDescription,
        InstitutionID, ResponsibilityID, DepartmentID,
        ClusterName, InstitutionName, ResponsibilityName, DepartmentName,
        LineNumber, LineDescription, MainGroup, SubGroupA, SubGroupB,
        [Oct],[Nov],[Dec],[Jan],[Feb],[Mar],[Apr],[May],[Jun],[Jul],[Aug],[Sep],
        Q1, Q2, Q3, Q4, YTDTotal, Approved, Routing, Allocation
    )
    SELECT
        FinancialYear, AccountID, AccountNumber, AccountDescription,
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

    /* ---- grain measurement (Access parity) --------------------------------
       The pre-parity snapshot was one row per account, so "two rows for an
       account" WAS the definition of a fan-out bug. The Access grain splits an
       account legitimately, which retires that test - so it is replaced by two
       narrower ones: a TRUE duplicate over the whole grain (51008, below), and
       a ceiling on how many accounts may split (@MaxSplitAccounts).
       Both are measured here and recorded on the refresh row either way. */
    SELECT @distinctAccounts = COUNT(DISTINCT AccountNumber)
    FROM dbo.FinanceLedgerSnapshot_Staging
    WHERE FinancialYear = @FinancialYear;

    SELECT @splitAccounts = COUNT(*)
    FROM (
        SELECT AccountNumber
        FROM dbo.FinanceLedgerSnapshot_Staging
        WHERE FinancialYear = @FinancialYear
        GROUP BY AccountNumber
        HAVING COUNT(*) > 1
    ) AS s;

    /* 51008. A TRUE fan-out: two rows identical across the whole grain. The
       Access grain is (FinancialYear, AccountID, AccountNumber,
       AccountDescription, InstitutionID, ResponsibilityID, DepartmentID) as
       stored - AccountN participates in the source GROUP BY but is not a
       snapshot column. Two rows agreeing on all of those are not a split, they
       are duplicated money, and no @Force may pass them. */
    SELECT @fanout = COUNT(*)
    FROM (
        SELECT 1 AS one
        FROM dbo.FinanceLedgerSnapshot_Staging
        WHERE FinancialYear = @FinancialYear
        GROUP BY AccountID, AccountNumber, AccountDescription,
                 InstitutionID, ResponsibilityID, DepartmentID
        HAVING COUNT(*) > 1
    ) AS f;

    IF @fanout > 0
    BEGIN
        DECLARE @fan nvarchar(600) = N'Refresh aborted for FY' + @FinancialYear + N': '
            + CONVERT(nvarchar(20), @fanout)
            + N' grain key(s) appear more than once in staging. That is duplicated money, not the '
            + N'Access account split - a split differs by AccountDescription (or a segment), a fan-out '
            + N'does not. Diagnose with sql/ParityReconciliation.sql before forcing anything; @Force '
            + N'does NOT bypass this gate, deliberately.';

        /* Clean up and RECORD before throwing. Gates 51004-51007 are preflight -
           they fire before staging is written, so a bare THROW leaves nothing
           behind. These two fire AFTER the staging build, so without this the
           year's rows would linger in staging and the refresh log would show no
           trace of the failure at all. Same shape as the @abort path below. */
        DELETE FROM dbo.FinanceLedgerSnapshot_Staging WHERE FinancialYear = @FinancialYear;

        MERGE dbo.FinanceLedgerRefresh AS t
        USING (SELECT @FinancialYear AS FinancialYear) AS s ON t.FinancialYear = s.FinancialYear
        WHEN MATCHED THEN UPDATE SET Outcome = 'ABORTED', Message = @fan
        WHEN NOT MATCHED THEN INSERT (FinancialYear, RefreshedAt, RowsLoaded, DurationSeconds, TotalAllocation, TotalYTD, TotalApproved, TotalRouting, UndefinedLabelPct, AccountsLoaded, SplitAccountCount, Outcome, Message)
             VALUES (@FinancialYear, SYSDATETIME(), 0, 0, 0, 0, 0, 0, 0, @distinctAccounts, @splitAccounts, 'ABORTED', @fan);

        THROW 51008, @fan, 1;
    END

    /* @MaxSplitAccounts. NOT bypassed by @Force - the all-years rebuild runs
       with @Force = 1 to clear the movement gates, and this must still hold, or
       it would protect nothing. The ceiling sits above the measured baseline
       (24 accounts across FY2014-FY2026) rather than at it, so ordinary source
       churn does not trip it while a NEW split driver does. */
    IF @splitAccounts > @MaxSplitAccounts
    BEGIN
        DECLARE @spl nvarchar(600) = N'Refresh aborted for FY' + @FinancialYear + N': '
            + CONVERT(nvarchar(20), @splitAccounts)
            + N' account(s) occupy more than one row, above the ceiling of '
            + CONVERT(nvarchar(20), @MaxSplitAccounts)
            + N'. Accounts split where the GL master and the COA corrections disagree on the '
            + N'description; a jump means a NEW driver. Name it (sql/ParityReconciliation.sql, test A4) '
            + N'and re-baseline @MaxSplitAccounts deliberately - do not raise it to make this pass.';

        -- Same reason as 51008 above: this fires after staging is built.
        DELETE FROM dbo.FinanceLedgerSnapshot_Staging WHERE FinancialYear = @FinancialYear;

        MERGE dbo.FinanceLedgerRefresh AS t
        USING (SELECT @FinancialYear AS FinancialYear) AS s ON t.FinancialYear = s.FinancialYear
        WHEN MATCHED THEN UPDATE SET Outcome = 'ABORTED', Message = @spl
        WHEN NOT MATCHED THEN INSERT (FinancialYear, RefreshedAt, RowsLoaded, DurationSeconds, TotalAllocation, TotalYTD, TotalApproved, TotalRouting, UndefinedLabelPct, AccountsLoaded, SplitAccountCount, Outcome, Message)
             VALUES (@FinancialYear, SYSDATETIME(), 0, 0, 0, 0, 0, 0, 0, @distinctAccounts, @splitAccounts, 'ABORTED', @spl);

        THROW 51009, @spl, 1;
    END

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
        WHEN NOT MATCHED THEN INSERT (FinancialYear, RefreshedAt, RowsLoaded, DurationSeconds, TotalAllocation, TotalYTD, TotalApproved, TotalRouting, UndefinedLabelPct, AccountsLoaded, SplitAccountCount, Outcome, Message)
             VALUES (@FinancialYear, SYSDATETIME(), 0, 0, 0, 0, 0, 0, 0, 0, 0, 'ABORTED', @abort);

        DECLARE @msg nvarchar(1200) = N'Refresh aborted for FY' + @FinancialYear + N': ' + @abort
                                    + N' Previous snapshot retained. Re-run with @Force = 1 if this movement is genuine.';
        THROW 51002, @msg, 1;
    END

    /* ---- swap ------------------------------------------------------------- */
    BEGIN TRANSACTION;

        DELETE FROM dbo.FinanceLedgerSnapshot WHERE FinancialYear = @FinancialYear;

        INSERT INTO dbo.FinanceLedgerSnapshot
        (
            FinancialYear, AccountID, AccountNumber, AccountDescription,
            InstitutionID, ResponsibilityID, DepartmentID,
            ClusterName, InstitutionName, ResponsibilityName, DepartmentName,
            LineNumber, LineDescription, MainGroup, SubGroupA, SubGroupB,
            [Oct],[Nov],[Dec],[Jan],[Feb],[Mar],[Apr],[May],[Jun],[Jul],[Aug],[Sep],
            Q1, Q2, Q3, Q4, YTDTotal, Approved, Routing, Allocation
        )
        SELECT
            FinancialYear, AccountID, AccountNumber, AccountDescription,
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
            AccountsLoaded = @distinctAccounts, SplitAccountCount = @splitAccounts,
            Outcome = 'OK', Message = NULL
        WHEN NOT MATCHED THEN INSERT (FinancialYear, RefreshedAt, RowsLoaded, DurationSeconds, TotalAllocation, TotalYTD, TotalApproved, TotalRouting, UndefinedLabelPct, AccountsLoaded, SplitAccountCount, Outcome, Message)
             VALUES (@FinancialYear, SYSDATETIME(), @rows, DATEDIFF(second, @startedAt, SYSDATETIME()), @alloc, @ytd, @approved, @routing, @undefPct, @distinctAccounts, @splitAccounts, 'OK', NULL);

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
        @undefPct      AS UndefinedLabelPct,
        @distinctAccounts AS AccountsLoaded,
        @splitAccounts    AS SplitAccountCount;
END
GO

/* ===========================================================================
   4. Verification - run these before the refresh in step 2.

   NOTE the COLLATE on both sides of every EXCEPT below. sys.columns.name is
   sysname (Latin1_General_CI_AS) while the name column returned by
   sys.dm_exec_describe_first_result_set takes the DATABASE collation
   (SQL_Latin1_General_CP1_CI_AS here), and EXCEPT will not resolve that for
   you - it raises Msg 468. The drift guard inside the procedure has always
   forced both sides for exactly this reason.
   =========================================================================== */
SET NOCOUNT ON;

-- Drift guard dry run: the function's columns vs the snapshot's, both ways.
-- Anything returned here means step 2 would THROW 51001.
SELECT 'in function, not in snapshot' AS direction, name COLLATE Latin1_General_CI_AS AS name
FROM sys.dm_exec_describe_first_result_set(N'SELECT * FROM dbo.fn_FinanceLedgerSource(''2026'')', NULL, 0)
EXCEPT
SELECT 'in function, not in snapshot', name COLLATE Latin1_General_CI_AS
FROM sys.columns WHERE object_id = OBJECT_ID('dbo.FinanceLedgerSnapshot');

SELECT 'in snapshot, not in function' AS direction, name COLLATE Latin1_General_CI_AS AS name
FROM sys.columns WHERE object_id = OBJECT_ID('dbo.FinanceLedgerSnapshot')
EXCEPT
SELECT 'in snapshot, not in function', name COLLATE Latin1_General_CI_AS
FROM sys.dm_exec_describe_first_result_set(N'SELECT * FROM dbo.fn_FinanceLedgerSource(''2026'')', NULL, 0);

/* The promoted function must be the one that was proven. Compared as TEXT, from
   RETURNS TABLE onward so the differing header comment and name are excluded.

   DO NOT compare these two functions by EXCEPTing their result sets. That looks
   more rigorous and is worse: each side inlines a query that scans ~641k GL rows,
   so the two directions together force FOUR full builds needing workspace memory
   inside single statements. On this instance (max server memory 2048 MB) it fails
   with Msg 701, insufficient system memory - which is exactly how this check was
   first written, and it is why sql/ParityReconciliation.sql materialises each
   side into a #temp table before comparing. The DATA proof belongs there (run
   order step 3); this is only asking "is the deployed body the proven body?". */
DECLARE @deployed nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID('dbo.fn_FinanceLedgerSource'));
DECLARE @proven   nvarchar(max) = OBJECT_DEFINITION(OBJECT_ID('dbo.fn_FinanceLedgerAccessParity'));

/* CR and LF are stripped before comparing. The two definitions reach the server
   through different paths - one file is assembled on the command line, the other
   edited on Windows - so one body carries CRLF and the other LF. That is not a
   difference in the query, and comparing raw text reports a false DIFFERENT. */
SELECT 'PROMOTED_BODY' AS chk,
    CASE
        WHEN @proven IS NULL
            THEN 'scratch function is gone - cannot verify; re-run sql/FinanceLedgerAccessParity.sql'
        WHEN REPLACE(REPLACE(SUBSTRING(@deployed, NULLIF(CHARINDEX('RETURNS TABLE', @deployed), 0), LEN(@deployed)), CHAR(13), ''), CHAR(10), '')
           = REPLACE(REPLACE(SUBSTRING(@proven,   NULLIF(CHARINDEX('RETURNS TABLE', @proven),   0), LEN(@proven)),   CHAR(13), ''), CHAR(10), '')
            THEN 'IDENTICAL to the proven body'
        ELSE 'DIFFERENT - stop and investigate before GATE 2'
    END AS verdict;
GO
