/* ===========================================================================
   FinanceLedgerAccessParity.sql
   ---------------------------------------------------------------------------
   dbo.fn_FinanceLedgerAccessParity(@FinancialYear)

   The Access-parity ledger source. Reproduces the finance department's Access
   query - sql/source/SQL Revised Allocation Oversight F.sql, SHA-256
   9f9f615854ed1ac5394b4b0da519e09d1df0cb8d665dc4d481ac8e5caef1d3ba - on MONEY
   and ROW GRAIN, while keeping the portal's label resolution and access
   enforcement.

   Design and rationale: financeupdatesep.md. Read Part A before editing.

   THIS IS A SCRATCH OBJECT (runbook Part E step 9 / GATE 1). It exists so
   parity can be PROVEN against dbo.fn_OversightDraftUnscoped before the live
   dbo.fn_FinanceLedgerSource is touched. Reversible by DROP FUNCTION.

   ---------------------------------------------------------------------------
   WHY THIS IS A REWRITE AND NOT A PATCH

   The deployed fn_FinanceLedgerSource guarantees ONE ROW PER ACCOUNT: it
   builds accountBase as a UNION of account NUMBERS, LEFT JOINs three wide
   aggregates onto it, and resolves AccountDescription AFTER the joins with no
   outer GROUP BY. Access does the opposite - a tall UNION ALL of three
   branches, then a PIVOT whose implicit grouping spans eight columns whose
   expressions DIFFER PER BRANCH. Where two branches disagree on any of those
   eight, the account splits into two rows. That is not a bug we can decline to
   reproduce; Finance reconciles against it.

   THE GRAIN IS THE GROUP BY LIST BELOW. It used to be an invisible emergent
   property of PIVOT, which is the root cause of this whole release, so it is
   written out explicitly here. Do not "simplify" it.

   WHAT IS DELIBERATELY *NOT* COPIED FROM THE DRAFT, and why each is provably
   free (financeupdatesep.md Part A, F3):

     1. PIVOT -> explicit GROUP BY + conditional SUM. Identical semantics;
        PIVOT is sugar for exactly this.
     2. FORMAT(TRXDate,'MMM') -> MONTH(TRXDate). FORMAT is culture-dependent:
        under a non-English session language it returns abbreviations matching
        no pivot column and yields SILENT ZEROS. 1:1 where the draft works.
     3. The draft's non-sargable per-row CASE on YEAR(CAST(ReqDateCreated AS
        DATE)) -> DATEFROMPARTS bounds. VERIFIED 2026-09-29: identical line set
        for every FY2014-FY2026 across all 108,435 open lines, 0 differences
        either direction, and ReqDateCreated is never NULL.
     4. Shipments stay PRE-AGGREGATED. Gate 4e counts open lines MATCHING a
        duplicated (PONumber, POLineID) - measured ZERO in every year - and
        where a key is not duplicated the raw join and the pre-aggregate return
        identical rows. Keeping the aggregate keeps the unique-index assertion.
     5. The access join stays in vw_FinanceLedger on dbo.vw_WebAppUserAccess
        (4-tuple DISTINCT + both IsActive filters). The draft's inline CTE has
        neither, so replicating it would grant a DEACTIVATED account data
        access. Identical output today; see financeupdatesep.md A8.
     6. The four segment NAME columns keep the portal's chain (sentinel
        normalisation, segment-level fallback, ISNULL 'UNDEFINED'). Names are
        neither money nor grain, so they are outside the parity mandate.

   AccountDescription is the exception to 6: it IS a PIVOT group key, therefore
   GRAIN, therefore taken verbatim per branch. That is what produces the split.

   ---------------------------------------------------------------------------
   AccountID's TYPE - a real trap, not a nicety.

   0098AFinGLMaster.AccountID is nvarchar(255); 0030ADGPCOA.AccountLineID is
   int. In the draft's UNION ALL, INT WINS datatype precedence, so the draft's
   AccountID column is silently an int and GL's strings are implicitly
   converted. It does not fail today, so every GL AccountID is numeric.
   We therefore declare it int EXPLICITLY on both branches rather than letting
   precedence decide - the schema-drift guard compares names only, so a type
   change here would be silent.
   =========================================================================== */

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER FUNCTION dbo.fn_FinanceLedgerAccessParity
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
