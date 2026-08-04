# Undo Runbook — Finance Ledger

How to reverse `sql/FinanceLedger.sql` and `sql/FinanceLedgerCutover.sql`.

Self-contained: you should not need to read anything else to use this.

Run in **SSMS**, connected to the affected server, database **`FinanceAutomationSystem`**, with a
login that can drop objects. The application login `finance` **cannot** — it is read-only on DDL.

> **Use `sql/FinanceLedgerRollback.sql`. Do not hand-write the drops.**
> After cutover the live views are defined *over* `dbo.vw_FinanceLedger`. Dropping objects in the
> wrong order breaks both pages **and** destroys the only copy of the original view definitions,
> with no way back. The script enforces the order and refuses the unsafe case.

---

## Which undo do you want?

| Situation | Use | Time | Rebuild needed after? |
|---|---|---|---|
| Pages are wrong / slow / broken **after cutover** — get back to how it was | **[Option A](#option-a--restore-the-old-views-urgent)** | seconds | **No** |
| Abandoning the work entirely, remove every trace | **[Option B](#option-b--remove-everything)** | seconds | Yes, 16–38 min if you return |
| You ran `FinanceLedger.sql` but **have not cut over** | **[Option B](#option-b--remove-everything)** | seconds | Yes, if you return |

**If in doubt, use Option A.** It is fully reversible, keeps the snapshot, and re-applying costs
seconds. Option B throws away 16–38 minutes of build.

---

## Option A — restore the old views (urgent)

Reverses **the cutover only**. The ledger objects and the snapshot stay exactly where they are.

### A1. Set the flags

Open `sql/FinanceLedgerRollback.sql` and set the two flags near the top:

```sql
DECLARE @RestoreLegacyViews bit = 1;
DECLARE @DropLedgerObjects  bit = 0;
```

### A2. Run the whole file

It prints the object state before and after. Expect:

```
restored dbo.MonthlyExpenditure from _Legacy
restored dbo.vw_BudgetAllocation from _Legacy
```

Safe to re-run — if the `_Legacy` views are already gone it reports "nothing to restore" and stops.

### A3. Verify

```sql
-- Expect: MonthlyExpenditure and vw_BudgetAllocation present, NEITHER _Legacy present
SELECT name, modify_date FROM sys.views
WHERE name IN ('MonthlyExpenditure','MonthlyExpenditure_Legacy',
               'vw_BudgetAllocation','vw_BudgetAllocation_Legacy',
               'vw_FinanceLedger')
ORDER BY name;

-- Expect: rows. Slow again (~80s) - that is the old view, and is correct here.
SELECT TOP 2 * FROM dbo.MonthlyExpenditure WHERE FinancialYear = '2026';

-- Expect: still present. Option A does NOT touch these.
SELECT COUNT(*) AS snapshotRows FROM dbo.FinanceLedgerSnapshot;
```

### What this does to the application

**Nothing breaks.** The two view names and their column lists are unchanged, so
`App\Models\MonthlyExpenditure` and `App\Models\BudgetAllocation` neither know nor care which
definition sits behind them. You are simply back to the old, slow Monthly Expenditure.

⚠ **One exception:** `/department-expenditure` and `/allocation-line-expenditure` read
`dbo.vw_FinanceLedger` directly. Option A leaves that view in place, so they keep working. **They
would break under Option B** — see below.

### Re-applying afterwards

```
sql/FinanceLedgerCutover.sql
```

Seconds. **No rebuild** — the snapshot survived. This round trip was tested on dev.

---

## Option B — remove everything

Restores the legacy views **and** drops all eight ledger objects.

### B1. Set the flags

```sql
DECLARE @RestoreLegacyViews bit = 1;   -- must ALSO be 1, see the guard
DECLARE @DropLedgerObjects  bit = 1;
```

### B2. Run the whole file

Expect the restore lines, then:

```
dropped  dbo.vw_FinanceLedger
dropped  dbo.vw_WebAppUserAccess
dropped  dbo.usp_RefreshFinanceLedgerSnapshotAll
dropped  dbo.usp_RefreshFinanceLedgerSnapshot
dropped  dbo.fn_FinanceLedgerSource
dropped  dbo.FinanceLedgerSnapshot_Staging
dropped  dbo.FinanceLedgerSnapshot
dropped  dbo.FinanceLedgerRefresh
```

### The guard you may hit

If you set `@DropLedgerObjects = 1` while a `_Legacy` view still exists, it throws and changes
nothing:

```
REFUSED: the cutover is still in place (a _Legacy view exists). The live views depend on
dbo.vw_FinanceLedger, so dropping it now would break them and lose the original definitions.
Re-run with @RestoreLegacyViews = 1 first.
```

That is working as intended. Set `@RestoreLegacyViews = 1` and run again.

### B3. Verify

```sql
-- Expect: ZERO rows
SELECT name, type_desc FROM sys.objects
WHERE name IN ('vw_WebAppUserAccess','fn_FinanceLedgerSource','FinanceLedgerSnapshot',
               'FinanceLedgerSnapshot_Staging','FinanceLedgerRefresh','vw_FinanceLedger',
               'usp_RefreshFinanceLedgerSnapshot','usp_RefreshFinanceLedgerSnapshotAll');

-- Expect: both present, no _Legacy
SELECT name FROM sys.views
WHERE name LIKE '%MonthlyExpenditure%' OR name LIKE '%BudgetAllocation%';
```

### ⚠ What this does to the application

**`/department-expenditure` and `/allocation-line-expenditure` will break.** Both controllers read
`dbo.vw_FinanceLedger`, which no longer exists. They degrade to their "The financial data source is
unavailable" state rather than erroring — but they show no data.

Dashboard, Budget Allocations and Monthly Expenditure keep working (they read the restored legacy
views).

If you are abandoning the work permanently, those two pages and their controllers should be removed
or reverted to the scaffold as well.

### Also disable the scheduler

Otherwise `ledger:refresh` fails nightly against objects that no longer exist:

- Disable or delete the Windows Task Scheduler tasks `SWRHA Finance - Scheduler` and
  `SWRHA Finance - Ledger Health Check`.
- Or comment out the two `Schedule::command('ledger:refresh'...)` entries in `routes/console.php`.

### Returning later

`sql/FinanceLedger.sql`, then a full snapshot build — **16–38 minutes**. That is the cost Option A
avoids.

---

## ⚠ Point of no return

`sql/FinanceLedgerCutover.sql` suggests dropping the `_Legacy` views once production has run on the
new ones long enough to trust:

```sql
DROP VIEW dbo.MonthlyExpenditure_Legacy;
DROP VIEW dbo.vw_BudgetAllocation_Legacy;
```

**After that, neither option here can restore the old views.** The `_Legacy` copies are the only
record of their original definitions.

Before dropping them, script both out and keep the file somewhere safe:

```sql
SELECT OBJECT_DEFINITION(OBJECT_ID('dbo.MonthlyExpenditure_Legacy'))  AS MonthlyExpenditure;
SELECT OBJECT_DEFINITION(OBJECT_ID('dbo.vw_BudgetAllocation_Legacy')) AS vw_BudgetAllocation;
```

Do not do the cleanup until at least one period close has passed on the new views.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Cannot drop ... because it does not exist or you do not have permission` | The login cannot drop objects | Use a login with DDL rights, not `finance` |
| `REFUSED: the cutover is still in place` | `@DropLedgerObjects = 1` with `_Legacy` still present | Set `@RestoreLegacyViews = 1` too, and re-run |
| Script reports "nothing to restore" | The cutover was never applied, or was already rolled back | Nothing to do — check the printed state |
| Connection times out / `TCP Provider: Timeout error [258]` | The instance is busy, often right after a big refresh | Wait and retry. Do not assume the server is down |
| Department / Allocation Line pages show "data source unavailable" after Option B | Expected — they read `vw_FinanceLedger`, which was dropped | Re-run `sql/FinanceLedger.sql` + rebuild, or revert those controllers |

---

## Tested

Both paths were exercised on dev (`V165ICTFA0MEL\SQLEXPRESS`):

- The guard correctly **refused** a drop while the cutover was live, and changed nothing.
- Option A restored the legacy views with `vw_FinanceLedger` and the snapshot intact.
- Re-applying `FinanceLedgerCutover.sql` afterwards returned all five pages to HTTP 200 with
  identical figures (TTD 74,327.48 budget / 71,362.68 spend) — **no rebuild required.**

Option B's full teardown was **not** executed on dev, because restoring it costs a full rebuild.
Its guard and its drop statements were verified individually.
