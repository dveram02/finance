/*==============================================================================================
  PHASE 3 ALL-YEARS ACCEPTANCE QUERY                                        read-only, no writes

  Purpose
  -------
  Since 2026-10-01 the fiscal year is an OPTIONAL filter on Encumbered Details and Routing
  Details, and both pages DEFAULT to every ELIGIBLE year. This script produces, for one user and
  one status set, the eight figures that acceptance is measured against.

  ⚠️ IT IS THE REFERENCE, NOT A COPY OF THE EXPECTED ANSWER. Acceptance is agreement between
  this query and the screen AT DEPLOY TIME. The numbers quoted in routingupdate.md section 2 are
  dated 2026-10-01 observations, useful for spotting an order-of-magnitude surprise and nothing
  more. Do not treat any of them as pass/fail.

  REFERENCE ONLY — never put this, or any part of it, behind a request path.

  How to run
  ----------
  Set @UserName, then uncomment the @Statuses line for the page under test:

      Encumbered Details  ->  AP, PO            (the ledger's Approved column)
      Routing Details     ->  RT, HD, PN        (the ledger's Routing column)

  What each result set must equal on the page, with All Fiscal Years selected:

    1  eligible year list .............. the Fiscal Year dropdown, EXACTLY and in that order
    2  withheld year list .............. the note under that dropdown
    3  row count ....................... rows.total
    4  SUM(ExtendedCost) ............... the totals row's money, to the cent
    5  ledger Approved / Routing ....... the SAME figure as 4 (this is the drill-down's whole
                                         promise, and Phase 2's gate enforces it in SQL)
    6  distinct (FinancialYear, Req) ... the Requisitions KPI
    7  largest single-year row count ... compare against FINANCE_REQUISITION_ROW_CEILING
    8  sort-key uniqueness ............. MUST RETURN NO ROWS, or pagination is not stable

  ----------------------------------------------------------------------------------------------
  TWO METHOD NOTES, both of which cost real measurements to learn
  ----------------------------------------------------------------------------------------------
  * CHECK 5 BINDS THE LEDGER TO THE SAME ELIGIBLE YEAR LIST, not to every year the ledger has.
    Measured 2026-10-01 the two agreed over the ledger's full 13-year boundary as well — but
    only because FY2022 and FY2023 ledger values happen to be zero. That is a coincidence of
    the data, not a property of the code.

  * CHECK 8 USES GROUP BY, NOT COUNT(DISTINCT CONCAT(...)). 685 rows carry a NULL Department
    and 20,648 an empty PONumber, and T-SQL CONCAT renders NULL as '' — so a concatenated key
    collides a NULL with an empty value. It can only manufacture FALSE duplicates, never hide
    real ones, but GROUP BY is the form to trust.

    Check 8 is also DIRECT, never inferred from dbo.FinanceRequisitionRefresh's
    DuplicateGrainRows. The two watch related keys — the sort key is DuplicateGrainRows' key
    (FinancialYear, RequisitionNumber, PONumber, LineNbr) plus Department, and a superset of a
    unique key is unique — so DuplicateGrainRows = 0 does prove the sort key unique. This check
    is the belt-and-braces for the release; the ONGOING protection has to be the refresh log,
    because that is computed every run while a manual query is not.
==============================================================================================*/

SET NOCOUNT ON;

DECLARE @UserName varchar(255) = 'FFIGUERA1';   --=========================== set me

-- The page's status set. Uncomment ONE.
DECLARE @Statuses TABLE (Status varchar(10) PRIMARY KEY);
INSERT INTO @Statuses (Status) VALUES ('AP'), ('PO');              -- Encumbered Details
-- INSERT INTO @Statuses (Status) VALUES ('RT'), ('HD'), ('PN');   -- Routing Details

PRINT '--- snapshot freshness (both tables; a step-2-only failure makes them disagree) ---';

SELECT 'requisition' AS snapshot_, MAX(RefreshedAt) AS refreshed_at
FROM dbo.FinanceRequisitionRefresh WHERE Outcome = 'OK'
UNION ALL
SELECT 'ledger', MAX(RefreshedAt)
FROM dbo.FinanceLedgerRefresh WHERE Outcome = 'OK';

/*----------------------------------------------------------------------------------------------
  The ELIGIBLE year set — this route's detail years INTERSECTED with the user's ledger years.
  Everything below is scoped to it, which is the whole of finding R1-A: the withheld years have
  no summary row to reconcile against, so including them breaks the reconciliation invariant
  silently. Measured 2026-10-01, the unbounded query leaked 49 rows / TTD 75,829.66.
----------------------------------------------------------------------------------------------*/
DECLARE @DetailYears TABLE (FinancialYear varchar(4) PRIMARY KEY);
INSERT INTO @DetailYears (FinancialYear)
SELECT DISTINCT CONVERT(varchar(4), d.FinancialYear)
FROM dbo.vw_FinanceRequisitionDetail AS d
WHERE d.UserName = @UserName
  AND d.Status IN (SELECT Status FROM @Statuses);

DECLARE @LedgerYears TABLE (FinancialYear varchar(4) PRIMARY KEY);
INSERT INTO @LedgerYears (FinancialYear)
SELECT DISTINCT CONVERT(varchar(4), l.FinancialYear)
FROM dbo.vw_FinanceLedger AS l
WHERE l.UserName = @UserName;

DECLARE @Eligible TABLE (FinancialYear varchar(4) PRIMARY KEY);
INSERT INTO @Eligible (FinancialYear)
SELECT FinancialYear FROM @DetailYears
INTERSECT
SELECT FinancialYear FROM @LedgerYears;

PRINT '--- 1. eligible years: the Fiscal Year dropdown, NEWEST FIRST ---';
-- NEWEST FIRST is the page's order too (availableYears() reverses the ascending source order),
-- and years[0] being the newest is what the suggested-year redirect depends on.
SELECT FinancialYear FROM @Eligible ORDER BY FinancialYear DESC;

PRINT '--- 2. withheld years: named under the dropdown, never silently dropped ---';
SELECT FinancialYear FROM @DetailYears
EXCEPT
SELECT FinancialYear FROM @LedgerYears;

PRINT '--- 3/4/6. row count, money and the requisitions KPI, over ALL eligible years ---';
SELECT
    COUNT(*)                                                     AS rows_total,
    CONVERT(decimal(19,2), SUM(d.ExtendedCost))                  AS sum_extended_cost,
    -- Keyed on (year, number), NOT the number alone: requisition numbers RECUR across fiscal
    -- years. Identical with one year selected; with All selected, counting the number alone
    -- merges a FY2019 and a FY2024 requisition. Measured 2026-10-01: 23,959 vs 24,065.
    COUNT(DISTINCT CONVERT(varchar(4), d.FinancialYear) + '|' + d.RequisitionNumber)
                                                                 AS distinct_requisitions,
    COUNT(DISTINCT d.RequisitionNumber)                          AS distinct_numbers_WRONG_KEY
FROM dbo.vw_FinanceRequisitionDetail AS d
WHERE d.UserName = @UserName
  AND d.Status IN (SELECT Status FROM @Statuses)
  AND CONVERT(varchar(4), d.FinancialYear) IN (SELECT FinancialYear FROM @Eligible);

PRINT '--- 5. the SAME money from the summary. the matching diff must be 0.00 ---';
-- BOTH ledger columns are returned and the operator reads the one matching @Statuses, rather
-- than this script building dynamic SQL to pick a column name. A hand-run reference query is
-- not worth an EXEC, and the pair side by side also makes it obvious that the OTHER column is
-- a different figure entirely — conflating Approved with Routing is the misreading the whole
-- phase exists to prevent.
SELECT
    (SELECT CONVERT(decimal(19,2), SUM(d.ExtendedCost))
     FROM dbo.vw_FinanceRequisitionDetail AS d
     WHERE d.UserName = @UserName
       AND d.Status IN (SELECT Status FROM @Statuses)
       AND CONVERT(varchar(4), d.FinancialYear) IN (SELECT FinancialYear FROM @Eligible)
    )                                                           AS detail_total,
    (SELECT CONVERT(decimal(19,2), SUM(l.Approved))
     FROM dbo.vw_FinanceLedger AS l
     WHERE l.UserName = @UserName
       AND CONVERT(varchar(4), l.FinancialYear) IN (SELECT FinancialYear FROM @Eligible)
    )                                                           AS summary_approved,
    (SELECT CONVERT(decimal(19,2), SUM(l.Routing))
     FROM dbo.vw_FinanceLedger AS l
     WHERE l.UserName = @UserName
       AND CONVERT(varchar(4), l.FinancialYear) IN (SELECT FinancialYear FROM @Eligible)
    )                                                           AS summary_routing;

PRINT '--- 7. largest SINGLE year, against FINANCE_REQUISITION_ROW_CEILING ---';
-- If this approaches the configured ceiling, section 12 item 2 of routingupdate.md reopens:
-- a single year over the ceiling has NO route to the data through this page at all, screen or
-- file, and the remedy is the deferred SQL-pushdown refactor. Measured snapshot-wide on
-- 2026-10-01: AP/PO FY2026 = 18,945 against a ceiling of 25,000 (~24% headroom, and FY2026 is
-- still accumulating). Note this is scoped to ONE user; the snapshot-wide figure is the one
-- that matters for capacity, and is measured without the UserName predicate.
SELECT TOP (5)
    CONVERT(varchar(4), d.FinancialYear) AS FinancialYear,
    COUNT(*)                             AS rows_in_year
FROM dbo.vw_FinanceRequisitionDetail AS d
WHERE d.UserName = @UserName
  AND d.Status IN (SELECT Status FROM @Statuses)
  AND CONVERT(varchar(4), d.FinancialYear) IN (SELECT FinancialYear FROM @Eligible)
GROUP BY CONVERT(varchar(4), d.FinancialYear)
ORDER BY COUNT(*) DESC;

PRINT '--- 8. sort-key uniqueness. MUST RETURN NO ROWS ---';
-- The application orders by exactly these five columns (FinancialYear DESC, then the four
-- below). A tie here means two rows could swap places between page requests, so a row can be
-- shown twice or not at all while paging. Snapshot-wide, not per user — the ordering is a
-- property of the data, not of who is reading it.
SELECT
    s.FinancialYear, s.Department, s.RequisitionNumber, s.LineNbr, s.PONumber,
    COUNT(*) AS tied_rows
FROM dbo.FinanceRequisitionSnapshot AS s
GROUP BY s.FinancialYear, s.Department, s.RequisitionNumber, s.LineNbr, s.PONumber
HAVING COUNT(*) > 1
ORDER BY COUNT(*) DESC;

PRINT '--- 8b. and the key the refresh proc already watches, for comparison ---';
-- DuplicateGrainRows' key. The sort key above is this plus Department, so it is a SUPERSET and
-- therefore unique whenever this is. Both returned 0 extra rows of 108,435 on 2026-10-01.
SELECT
    s.FinancialYear, s.RequisitionNumber, s.PONumber, s.LineNbr,
    COUNT(*) AS tied_rows
FROM dbo.FinanceRequisitionSnapshot AS s
GROUP BY s.FinancialYear, s.RequisitionNumber, s.PONumber, s.LineNbr
HAVING COUNT(*) > 1
ORDER BY COUNT(*) DESC;

GO
