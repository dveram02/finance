/* ===========================================================================
   WHAT THE APP RETURNS - Allocations, Encumbered (Approved) and Routing
   ---------------------------------------------------------------------------
   PURPOSE
     Reproduce, in SSMS, EXACTLY the row sets the running application builds
     for three of its pages, so they can be diffed against the finance team's
     original scripts:

       /budget-allocations   <- dbo.vw_BudgetAllocation           (section 2)
       /encumbered-details   <- dbo.vw_FinanceRequisitionDetail   (section 3)
                                Status IN ('AP','PO')
       /routing-details      <- dbo.vw_FinanceRequisitionDetail   (section 4)
                                Status IN ('RT','HD','PN')

     Every projection, filter and ORDER BY below is lifted from the controller
     that renders the page:
       BudgetAllocationController::resolve() / applyOrder()
       RequisitionDetailController::detailRows() / COLUMNS
       EncumberedDetailsController / RoutingDetailsController (the status sets)

   READ-ONLY. Nothing here writes, creates or drops anything (bar one temp
   table for the parameters). Safe on production. Run against the
   FinanceAutomationSystem database.

   HOW IT DIFFERS FROM THE ORIGINAL SCRIPTS - expect these, they are not bugs
     1. The originals recompute the whole ledger / requisition build from the
        base tables. These read the SNAPSHOTS through the views, so they answer
        "what does the app show TONIGHT", not "what would a rebuild produce".
        A difference here can mean the snapshot is stale or a refresh aborted -
        check section 7 before suspecting the SQL.
     2. The originals carry NO fiscal-year filter; the app pages are always
        locked to one FY. Section 5 gives the all-years variants for a
        like-for-like total against the originals.
     3. The originals' final projection is 17 columns in their own order; the
        app fetches 25. Section 5.3 emits the originals' exact 17, in their
        order, so the two result grids can be pasted side by side.
     4. Money here is already NET OF RECEIPTS and floored at zero
        (Quantity = ActBalance, ExtendedCost = ActCost). Do not compare against
        the source tables' raw ExtendedCost - that double-counts a received
        line, once as a commitment and again as GL actual.

   PARAMETERS - set the two values in section 0, then run the whole file (F5).
   =========================================================================== */

USE [FinanceAutomationSystem];
GO

SET NOCOUNT ON;
GO


/* ===========================================================================
   0. PARAMETERS
   ---------------------------------------------------------------------------
   SSMS ends a batch at every GO, so the two values are stashed in a temp table
   rather than retyped in each section. Change them here only.
   =========================================================================== */

IF OBJECT_ID('tempdb..#p') IS NOT NULL DROP TABLE #p;

/* COLLATE DATABASE_DEFAULT is not decoration: a temp table takes tempdb's
   collation, and vw_WebAppUserAccess reads UserName across a database
   boundary. Without it, a server whose tempdb collation differs from this
   database's fails every join below with a collation conflict. */
SELECT
    CONVERT(varchar(100), 'KCHARLES1') COLLATE DATABASE_DEFAULT AS UserName,  -- the user whose pages you are checking
    CONVERT(varchar(10),  '2026')      COLLATE DATABASE_DEFAULT AS FY         -- the fiscal year the page is on
INTO #p;

SELECT 'parameters' AS check_name, UserName, FY FROM #p;
GO


/* ===========================================================================
   1. SANITY - run this FIRST and read it
   ---------------------------------------------------------------------------
   An empty page is almost always a missing ACCESS MAPPING, not a query
   defect. 1a must return a row; if it does not, every section below is
   legitimately empty and there is nothing to compare.
   =========================================================================== */

/* 1a. What this user can see at all. No row = no mapping = empty app. */
SELECT 'access grants' AS check_name,
       ua.UserName,
       COUNT(*)                         AS grant_rows,
       COUNT(DISTINCT ua.InstitutionID) AS institutions,
       COUNT(DISTINCT ua.DepartmentID)  AS departments
FROM dbo.vw_WebAppUserAccess AS ua
INNER JOIN #p AS p ON p.UserName = ua.UserName
GROUP BY ua.UserName;

/* 1b. The fiscal years each page offers this user.
       NOTE the two requisition pages' rail is the INTERSECTION of the ledger
       and requisition years - the detail snapshot holds years the ledger does
       not, and the app deliberately withholds them (they would reconcile
       against nothing) while naming them on the page. */
SELECT 'ledger years' AS source, l.FinancialYear
FROM dbo.vw_FinanceLedger AS l INNER JOIN #p AS p ON p.UserName = l.UserName
GROUP BY l.FinancialYear
UNION ALL
SELECT 'allocation years', b.FinancialYear
FROM dbo.vw_BudgetAllocation AS b INNER JOIN #p AS p ON p.UserName = b.UserName
GROUP BY b.FinancialYear
UNION ALL
SELECT 'requisition years', r.FinancialYear
FROM dbo.vw_FinanceRequisitionDetail AS r INNER JOIN #p AS p ON p.UserName = r.UserName
GROUP BY r.FinancialYear
ORDER BY source, FinancialYear;

/* 1c. Fan-out guard. MUST return nothing. Any row means the access join is
       duplicating and every money figure on every page is doubled. */
SELECT TOP (10) 'FAN-OUT - money is doubling' AS alert,
       FinancialYear, UserName, AccountNumber, COUNT(*) AS times_matched
FROM dbo.vw_FinanceLedger
GROUP BY FinancialYear, UserName, AccountNumber
HAVING COUNT(*) > 1;
GO


/* ===========================================================================
   2. ALLOCATIONS - the /budget-allocations page
   ---------------------------------------------------------------------------
   Source: dbo.vw_BudgetAllocation, a thin projection over vw_FinanceLedger
   with WHERE Allocation <> 0 - a budget page lists things that were BUDGETED,
   so accounts with no allocation are excluded even though the ledger carries
   them.

   Scope is GOODS AND SERVICES ONLY - reporting line 3's 41 account codes.
   Payroll is excluded by design; "the total looks far too low" traces here.
   =========================================================================== */

/* 2a. The table, in the page's exact order (applyOrder()). The page paginates
       at 25; this is the whole set, which is what the CSV export streams. */
SELECT
    b.FinancialYear,
    b.ClusterName,
    b.InstitutionName,
    b.ResponsibilityName,
    b.DepartmentName,
    b.AccountDescription,
    b.AccountNumber,
    b.TotalAllocation
FROM dbo.vw_BudgetAllocation AS b
INNER JOIN #p AS p
        ON p.UserName = b.UserName
       AND p.FY       = b.FinancialYear
ORDER BY b.FinancialYear, b.ClusterName, b.InstitutionName,
         b.DepartmentName, b.AccountNumber;

/* 2b. The page's KPI cards, over the WHOLE filtered set (before pagination).
       These are the numbers to diff against the original script's totals. */
SELECT
    'budget allocations - stats' AS check_name,
    COUNT(*)                         AS [rows],
    SUM(b.TotalAllocation)           AS total_allocation,
    MAX(b.TotalAllocation)           AS largest_allocation,
    COUNT(DISTINCT b.AccountNumber)  AS accounts,
    COUNT(DISTINCT b.DepartmentName) AS departments
FROM dbo.vw_BudgetAllocation AS b
INNER JOIN #p AS p ON p.UserName = b.UserName AND p.FY = b.FinancialYear;

/* 2c. The largest line with its label - the KPI card's sub-label. */
SELECT TOP (1) 'largest allocation' AS check_name,
       b.AccountNumber, b.AccountDescription, b.DepartmentName, b.TotalAllocation
FROM dbo.vw_BudgetAllocation AS b
INNER JOIN #p AS p ON p.UserName = b.UserName AND p.FY = b.FinancialYear
ORDER BY b.TotalAllocation DESC;

/* 2d. By department - the shape a finance reviewer usually checks by hand. */
SELECT b.DepartmentName,
       COUNT(*)               AS accounts,
       SUM(b.TotalAllocation) AS total_allocation
FROM dbo.vw_BudgetAllocation AS b
INNER JOIN #p AS p ON p.UserName = b.UserName AND p.FY = b.FinancialYear
GROUP BY b.DepartmentName
ORDER BY total_allocation DESC;
GO


/* ===========================================================================
   3. ENCUMBERED DETAILS - the /encumbered-details page
   ---------------------------------------------------------------------------
   Status IN ('AP','PO') - approved requisitions and raised purchase orders.
   This is the requisition-LINE grain behind the ledger's account-grain
   Approved column. Same money, two grains.

   Quantity     = the UNSHIPPED balance (the view aliases ActBalance), floored
                  at zero so an over-shipped line is not a negative commitment
   ExtendedCost = Quantity x UnitCost, the commitment NET OF RECEIPTS
   OrderQuantity / QtyShipped are carried so that netting is auditable on the
   row itself.
   =========================================================================== */

/* 3a. The table - the app's 25 fetched columns, in the app's order
       (RequisitionDetailController::COLUMNS, ordered by detailRows()). */
SELECT
    r.FinancialYear,
    r.RequisitionNumber,
    r.PONumber,
    r.LineNbr,
    r.[Status],
    r.StatusName,
    r.ReqDateCreated,
    r.[Name],
    r.VendorID,
    r.VendorName,
    r.ItemID,
    r.ItemDescription,
    r.UofM,
    r.SiteLocation,
    r.Cluster,
    r.Institution,
    r.ResponsibilityCentre,
    r.Department,
    r.AccountNumber,
    r.AccountDescription,
    r.OrderQuantity,
    r.QtyShipped,
    r.Quantity,
    r.UnitCost,
    r.ExtendedCost
FROM dbo.vw_FinanceRequisitionDetail AS r
INNER JOIN #p AS p
        ON p.UserName = r.UserName
       AND p.FY       = r.FinancialYear
WHERE r.[Status] IN ('AP', 'PO')
ORDER BY r.Department, r.RequisitionNumber, r.LineNbr;

/* 3b. The page's totals row and KPI cards, over the whole filtered set.
       `requisitions` counts DISTINCT requisition numbers, not lines - a
       requisition with nine lines is one requisition. */
SELECT
    'encumbered - totals' AS check_name,
    SUM(r.ExtendedCost)                 AS committed,
    SUM(r.Quantity)                     AS quantity,
    COUNT(*)                            AS lines,
    COUNT(DISTINCT r.RequisitionNumber) AS requisitions,
    COUNT(DISTINCT r.VendorName)        AS vendors,
    COUNT(DISTINCT r.AccountNumber)     AS accounts
FROM dbo.vw_FinanceRequisitionDetail AS r
INNER JOIN #p AS p ON p.UserName = r.UserName AND p.FY = r.FinancialYear
WHERE r.[Status] IN ('AP', 'PO');

/* 3c. Split by status - AP and PO are both "approved" but mean different
       things to a buyer, and the page offers them as separate filter values. */
SELECT r.[Status], r.StatusName,
       COUNT(*)            AS lines,
       SUM(r.ExtendedCost) AS committed
FROM dbo.vw_FinanceRequisitionDetail AS r
INNER JOIN #p AS p ON p.UserName = r.UserName AND p.FY = r.FinancialYear
WHERE r.[Status] IN ('AP', 'PO')
GROUP BY r.[Status], r.StatusName
ORDER BY r.[Status];
GO


/* ===========================================================================
   4. ROUTING DETAILS - the /routing-details page
   ---------------------------------------------------------------------------
   Status IN ('RT','HD','PN') - in routing, on hold, pending. The pre-PO
   pipeline behind the ledger's Routing column. These carry no shipments, so
   nothing is netted off: QtyShipped is 0 and Quantity = OrderQuantity.

   Routing is DISPLAYED and deducted from nothing - only posted GL reduces the
   allocation balance. See 6d.
   =========================================================================== */

/* 4a. The table - identical projection and order to 3a, different status set.
       One schema for both pages, so the two exports can be safely unioned. */
SELECT
    r.FinancialYear,
    r.RequisitionNumber,
    r.PONumber,
    r.LineNbr,
    r.[Status],
    r.StatusName,
    r.ReqDateCreated,
    r.[Name],
    r.VendorID,
    r.VendorName,
    r.ItemID,
    r.ItemDescription,
    r.UofM,
    r.SiteLocation,
    r.Cluster,
    r.Institution,
    r.ResponsibilityCentre,
    r.Department,
    r.AccountNumber,
    r.AccountDescription,
    r.OrderQuantity,
    r.QtyShipped,
    r.Quantity,
    r.UnitCost,
    r.ExtendedCost
FROM dbo.vw_FinanceRequisitionDetail AS r
INNER JOIN #p AS p
        ON p.UserName = r.UserName
       AND p.FY       = r.FinancialYear
WHERE r.[Status] IN ('RT', 'HD', 'PN')
ORDER BY r.Department, r.RequisitionNumber, r.LineNbr;

/* 4b. The page's totals row and KPI cards. */
SELECT
    'routing - totals' AS check_name,
    SUM(r.ExtendedCost)                 AS committed,
    SUM(r.Quantity)                     AS quantity,
    COUNT(*)                            AS lines,
    COUNT(DISTINCT r.RequisitionNumber) AS requisitions,
    COUNT(DISTINCT r.VendorName)        AS vendors,
    COUNT(DISTINCT r.AccountNumber)     AS accounts
FROM dbo.vw_FinanceRequisitionDetail AS r
INNER JOIN #p AS p ON p.UserName = r.UserName AND p.FY = r.FinancialYear
WHERE r.[Status] IN ('RT', 'HD', 'PN');

/* 4c. Split by status. */
SELECT r.[Status], r.StatusName,
       COUNT(*)            AS lines,
       SUM(r.ExtendedCost) AS committed
FROM dbo.vw_FinanceRequisitionDetail AS r
INNER JOIN #p AS p ON p.UserName = r.UserName AND p.FY = r.FinancialYear
WHERE r.[Status] IN ('RT', 'HD', 'PN')
GROUP BY r.[Status], r.StatusName
ORDER BY r.[Status];
GO


/* ===========================================================================
   5. LIKE-FOR-LIKE WITH THE ORIGINAL SCRIPTS
   ---------------------------------------------------------------------------
   The originals have no fiscal-year filter and end on a 17-column projection
   in their own order. Use these to diff without hand-editing either side.
   =========================================================================== */

/* 5a. ALL YEARS, encumbered - the original Approved script's scope.
       Per year plus a ROLLUP total, so one mismatched year is visible rather
       than buried inside a single grand total. */
SELECT 'encumbered - all years' AS check_name,
       r.FinancialYear,
       COUNT(*)            AS lines,
       SUM(r.ExtendedCost) AS committed
FROM dbo.vw_FinanceRequisitionDetail AS r
INNER JOIN #p AS p ON p.UserName = r.UserName
WHERE r.[Status] IN ('AP', 'PO')
GROUP BY ROLLUP (r.FinancialYear)
ORDER BY r.FinancialYear;

/* 5b. ALL YEARS, routing - the original Routing script's scope. */
SELECT 'routing - all years' AS check_name,
       r.FinancialYear,
       COUNT(*)            AS lines,
       SUM(r.ExtendedCost) AS committed
FROM dbo.vw_FinanceRequisitionDetail AS r
INNER JOIN #p AS p ON p.UserName = r.UserName
WHERE r.[Status] IN ('RT', 'HD', 'PN')
GROUP BY ROLLUP (r.FinancialYear)
ORDER BY r.FinancialYear;

/* 5c. The ORIGINALS' exact 17 columns, in the originals' order, all years.
       Paste this grid beside the original script's grid and compare directly.
       Change the status list on the marked line for the other page.
       The ORDER BY is added only so two otherwise unordered sets line up. */
SELECT
    r.RequisitionNumber,
    r.PONumber,
    r.StatusName,
    r.LineNbr,
    r.ItemDescription,
    r.AccountDescription,
    r.ReqDateCreated,
    r.UofM,
    r.Quantity,        -- the view already aliases the source's ActBalance to this
    r.UnitCost,
    r.ExtendedCost,    -- ...and ActCost to this
    r.Cluster,
    r.Institution,
    r.Department,
    r.ResponsibilityCentre,
    r.VendorName,
    r.FinYear
FROM dbo.vw_FinanceRequisitionDetail AS r
INNER JOIN #p AS p ON p.UserName = r.UserName
WHERE r.[Status] IN ('AP', 'PO')     -- <<< change to ('RT','HD','PN') for routing
ORDER BY r.RequisitionNumber, r.LineNbr;

/* 5d. ALL YEARS, allocations - the original allocation script's scope.
       vw_BudgetAllocation holds FY2025 onward only, because
       0040CBudgetsAllocation has no earlier rows. A shorter rail than the
       ledger's is source data, not a filter defect. */
SELECT 'allocations - all years' AS check_name,
       b.FinancialYear,
       COUNT(*)               AS [rows],
       SUM(b.TotalAllocation) AS total_allocation
FROM dbo.vw_BudgetAllocation AS b
INNER JOIN #p AS p ON p.UserName = b.UserName
GROUP BY ROLLUP (b.FinancialYear)
ORDER BY b.FinancialYear;
GO


/* ===========================================================================
   6. RECONCILIATION - detail against the summary the app shows elsewhere
   ---------------------------------------------------------------------------
   This is the check that actually catches a defect. The two detail pages are
   DRILL-DOWNS: their Extended Cost must sum, per account, to the ledger's
   Approved and Routing. The Phase 2 refresh gate enforces that at build time;
   this verifies it is still true for THIS user and THIS year, through the
   access-scoped views the app actually reads.
   =========================================================================== */

/* 6a. Grand totals. approved_diff and routing_diff must both be 0.00.
       A non-zero here alongside a large drift in section 7 is a STALE
       SNAPSHOT, not a query defect - rebuild before investigating further. */
WITH led AS (
    SELECT SUM(l.Approved) AS Approved, SUM(l.Routing) AS Routing
    FROM dbo.vw_FinanceLedger AS l
    INNER JOIN #p AS p ON p.UserName = l.UserName AND p.FY = l.FinancialYear
),
det AS (
    SELECT
        SUM(CASE WHEN r.[Status] IN ('AP','PO')      THEN r.ExtendedCost ELSE 0 END) AS Approved,
        SUM(CASE WHEN r.[Status] IN ('RT','HD','PN') THEN r.ExtendedCost ELSE 0 END) AS Routing
    FROM dbo.vw_FinanceRequisitionDetail AS r
    INNER JOIN #p AS p ON p.UserName = r.UserName AND p.FY = r.FinancialYear
)
SELECT 'summary vs detail' AS check_name,
       led.Approved AS ledger_approved, det.Approved AS detail_approved,
       led.Approved - det.Approved AS approved_diff,
       led.Routing  AS ledger_routing,  det.Routing  AS detail_routing,
       led.Routing  - det.Routing  AS routing_diff
FROM led CROSS JOIN det;

/* 6b. Per account - only the accounts that DISAGREE. Must return nothing.
       A FULL JOIN, so an account present on one side only is caught too. */
WITH led AS (
    SELECT l.AccountNumber, l.Approved, l.Routing
    FROM dbo.vw_FinanceLedger AS l
    INNER JOIN #p AS p ON p.UserName = l.UserName AND p.FY = l.FinancialYear
),
det AS (
    SELECT r.AccountNumber,
           SUM(CASE WHEN r.[Status] IN ('AP','PO')      THEN r.ExtendedCost ELSE 0 END) AS Approved,
           SUM(CASE WHEN r.[Status] IN ('RT','HD','PN') THEN r.ExtendedCost ELSE 0 END) AS Routing
    FROM dbo.vw_FinanceRequisitionDetail AS r
    INNER JOIN #p AS p ON p.UserName = r.UserName AND p.FY = r.FinancialYear
    GROUP BY r.AccountNumber
)
SELECT COALESCE(led.AccountNumber, det.AccountNumber) AS AccountNumber,
       led.Approved AS ledger_approved, det.Approved AS detail_approved,
       ISNULL(led.Approved,0) - ISNULL(det.Approved,0) AS approved_diff,
       led.Routing  AS ledger_routing,  det.Routing  AS detail_routing,
       ISNULL(led.Routing,0)  - ISNULL(det.Routing,0)  AS routing_diff
FROM led
FULL JOIN det ON det.AccountNumber = led.AccountNumber
WHERE ABS(ISNULL(led.Approved,0) - ISNULL(det.Approved,0)) > 0.005
   OR ABS(ISNULL(led.Routing,0)  - ISNULL(det.Routing,0))  > 0.005
ORDER BY AccountNumber;

/* 6c. Allocations against the ledger they are projected from. Must be 0.00.
       The row counts differ legitimately - vw_BudgetAllocation drops the
       Allocation = 0 accounts - so only the money is compared, and the count
       difference is reported as what it is. */
WITH led AS (
    SELECT SUM(l.Allocation) AS Allocation, COUNT(*) AS ledger_rows
    FROM dbo.vw_FinanceLedger AS l
    INNER JOIN #p AS p ON p.UserName = l.UserName AND p.FY = l.FinancialYear
),
alloc AS (
    SELECT SUM(b.TotalAllocation) AS Allocation, COUNT(*) AS allocation_rows
    FROM dbo.vw_BudgetAllocation AS b
    INNER JOIN #p AS p ON p.UserName = b.UserName AND p.FY = b.FinancialYear
)
SELECT 'allocation vs ledger' AS check_name,
       led.Allocation                     AS ledger_allocation,
       alloc.Allocation                   AS page_allocation,
       led.Allocation - alloc.Allocation  AS allocation_diff,
       led.ledger_rows,
       alloc.allocation_rows,
       led.ledger_rows - alloc.allocation_rows AS zero_allocation_accounts
FROM led CROSS JOIN alloc;

/* 6d. The balance rule, as the app reports it (changed 2026-08-25):
       ONLY posted GL reduces the balance. Approved is reported but does not
       reduce it; Routing is deducted from nothing at all.
         ActualExpenditure = YTDTotal + Approved
         AllocationBalance = MAX(0, Allocation - YTDTotal)
         Excess            = MAX(0, YTDTotal - Allocation) */
SELECT 'ledger totals (balance rule)' AS check_name,
       SUM(l.Allocation)        AS allocation,
       SUM(l.YTDTotal)          AS ytd_posted_gl,
       SUM(l.Approved)          AS approved_encumbered,
       SUM(l.Routing)           AS routing_not_deducted,
       SUM(l.ActualExpenditure) AS actual_expenditure,
       SUM(l.AllocationBalance) AS allocation_balance,
       SUM(l.Excess)            AS excess
FROM dbo.vw_FinanceLedger AS l
INNER JOIN #p AS p ON p.UserName = l.UserName AND p.FY = l.FinancialYear;
GO


/* ===========================================================================
   7. SNAPSHOT PROVENANCE - read this before believing any difference above
   ---------------------------------------------------------------------------
   Both snapshots are built by TWO STEPS of ONE nightly Agent job. Step 1 can
   succeed while step 2 fails: both tables then look individually fresh while
   being from different nights, and the detail silently disagrees with the
   summary. That is exactly what section 6 would report as a "difference".
   =========================================================================== */

SELECT TOP (5) 'ledger refresh' AS log, *
FROM dbo.FinanceLedgerRefresh
ORDER BY RefreshedAt DESC;

SELECT TOP (5) 'requisition refresh' AS log, *
FROM dbo.FinanceRequisitionRefresh
ORDER BY RefreshedAt DESC;

/* Drift between the two. Anything beyond a few minutes means they are from
   different runs and section 6 cannot be trusted until both are rebuilt.
   This is the same condition `php artisan ledger:status` exits non-zero on. */
SELECT 'snapshot drift' AS check_name,
       (SELECT MAX(RefreshedAt) FROM dbo.FinanceLedgerRefresh      WHERE Outcome = 'OK') AS ledger_ok_at,
       (SELECT MAX(RefreshedAt) FROM dbo.FinanceRequisitionRefresh WHERE Outcome = 'OK') AS requisition_ok_at,
       DATEDIFF(minute,
           (SELECT MAX(RefreshedAt) FROM dbo.FinanceLedgerRefresh      WHERE Outcome = 'OK'),
           (SELECT MAX(RefreshedAt) FROM dbo.FinanceRequisitionRefresh WHERE Outcome = 'OK')) AS drift_minutes;
GO


/* ---- tidy up ------------------------------------------------------------ */
IF OBJECT_ID('tempdb..#p') IS NOT NULL DROP TABLE #p;
GO
