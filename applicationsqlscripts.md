# Application SQL Scripts

The `SELECT` each report page issues, with the **user** and **fiscal year** filters set inline.
Every query is self-contained — change the two `DECLARE` lines at the top of a block, paste it into
SSMS against `FinanceAutomationSystem`, run it.

All five are read-only and already user-scoped by the view's access join.

| # | Report | Source view |
|---|---|---|
| 1 | Budget Allocations | `dbo.vw_BudgetAllocation` |
| 2 | Monthly Expenditure | `dbo.vw_FinanceLedger` |
| 3 | Variance | `dbo.vw_FinanceLedger` |
| 4 | Encumbered Details | `dbo.vw_FinanceRequisitionDetail` (`AP`, `PO`) |
| 5 | Routing Details | `dbo.vw_FinanceRequisitionDetail` (`RT`, `HD`, `PN`) |

---

## 1. Budget Allocations

```sql
USE [FinanceAutomationSystem];

DECLARE @UserName varchar(100) = 'KCHARLES1';
DECLARE @FY       varchar(10)  = '2026';

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
WHERE b.UserName      = @UserName
  AND b.FinancialYear = @FY
ORDER BY b.FinancialYear, b.ClusterName, b.InstitutionName,
         b.DepartmentName, b.AccountNumber;
```

---

## 2. Monthly Expenditure

One row per account, the twelve fiscal months across. `PeriodID` 1 = Oct … 12 = Sep, so the month
columns are in fiscal order, not calendar order.

```sql
USE [FinanceAutomationSystem];

DECLARE @UserName varchar(100) = 'KCHARLES1';
DECLARE @FY       varchar(10)  = '2026';

SELECT
    l.FinancialYear,
    l.ClusterName,
    l.InstitutionName,
    l.Responsibility,
    l.DepartmentName,
    l.AccountNumber,
    l.AccountDescription,
    l.[Oct], l.[Nov], l.[Dec],
    l.[Jan], l.[Feb], l.[Mar],
    l.[Apr], l.[May], l.[Jun],
    l.[Jul], l.[Aug], l.[Sep],
    l.YTDTotal
FROM dbo.vw_FinanceLedger AS l
WHERE l.UserName      = @UserName
  AND l.FinancialYear = @FY
ORDER BY l.ClusterName, l.InstitutionName, l.DepartmentName, l.AccountNumber;
```

---

## 3. Variance

Allocation against actual spend per account line. Only posted GL (`YTDTotal`) reduces the balance:
`Approved` is reported in `ActualExpenditure` but does not reduce it, and `Routing` is deducted from
nothing. `Excess` and `AllocationBalance` are floored at zero, so exactly one of the two is non-zero
on any row.

```sql
USE [FinanceAutomationSystem];

DECLARE @UserName varchar(100) = 'KCHARLES1';
DECLARE @FY       varchar(10)  = '2026';

SELECT
    l.FinancialYear,
    l.ClusterName,
    l.InstitutionName,
    l.Responsibility,
    l.DepartmentName,
    l.AccountNumber,
    l.AccountDescription,
    l.Allocation,
    l.Approved,
    l.Routing,
    l.YTDTotal,
    l.ActualExpenditure,
    l.Excess,
    l.AllocationBalance,
    l.[Oct], l.[Nov], l.[Dec],
    l.[Jan], l.[Feb], l.[Mar],
    l.[Apr], l.[May], l.[Jun],
    l.[Jul], l.[Aug], l.[Sep]
FROM dbo.vw_FinanceLedger AS l
WHERE l.UserName      = @UserName
  AND l.FinancialYear = @FY
ORDER BY l.ClusterName, l.InstitutionName, l.DepartmentName, l.AccountNumber;
```

---

## 4. Encumbered Details

The requisition **lines** behind the ledger's `Approved` column. `Quantity` is the unshipped
balance (the view aliases `ActBalance` to it) and `ExtendedCost` is `Quantity × UnitCost` — the
commitment net of receipts, floored at zero. `OrderQuantity` and `QtyShipped` are carried so that
netting is auditable on the row.

```sql
USE [FinanceAutomationSystem];

DECLARE @UserName varchar(100) = 'KCHARLES1';
DECLARE @FY       varchar(10)  = '2026';

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
WHERE r.UserName      = @UserName
  AND r.FinancialYear = @FY
  AND r.[Status] IN ('AP', 'PO')
ORDER BY r.Department, r.RequisitionNumber, r.LineNbr;
```

---

## 5. Routing Details

The requisition **lines** behind the ledger's `Routing` column — in routing, on hold, pending.
Identical projection to Encumbered Details, different status set. These carry no shipments, so
`QtyShipped` is 0 and `Quantity` equals `OrderQuantity`.

```sql
USE [FinanceAutomationSystem];

DECLARE @UserName varchar(100) = 'KCHARLES1';
DECLARE @FY       varchar(10)  = '2026';

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
WHERE r.UserName      = @UserName
  AND r.FinancialYear = @FY
  AND r.[Status] IN ('RT', 'HD', 'PN')
ORDER BY r.Department, r.RequisitionNumber, r.LineNbr;
```
