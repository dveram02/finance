> **NOTE (2026-08-25):** every linked-server prerequisite in this runbook is **OBSOLETE 2026-08-25**.
> `fn_FinanceLedgerSource` now reads the local chart of accounts (`0030ADGPCOA` +
> `0030AEAccountNameCorrections`) and does not touch `[GPSWRHA.SWRHA.CO.TT]` at all, so the
> linked-server connectivity and login-mapping gates no longer guard anything. Skip them.
> Everything else in this document still applies.

# Production Rollout — Finance Unified Ledger

Step-by-step procedure for applying the unified ledger migration to production.

**Read first:** `financeupdateprogress.md` (what was built and why) and `financeupdate.md`
(design rationale). This file is the runbook only.

---

## Before you start

| | |
|---|---|
| Estimated total | **1.5–3 hours**, most of it the snapshot build running unattended |
| User-visible downtime | **None** if steps run in order. The cutover itself is metadata-only (seconds). |
| Point of no return | **None** — step 8 is reversible in seconds (see [Rollback](#rollback)) |
| Can be paused | Yes, after any step. Steps 1–6 change nothing the app reads. |

### What you need

- A SQL Server login on production with rights to `CREATE`/`ALTER` views, functions, procedures
  and tables in `FinanceAutomationSystem`, and to `sp_rename` two views.
- Deploy access to the application server (to release code and run `php artisan`).
- Confirmation that the linked server `GPSWRHA.SWRHA.CO.TT` is reachable from production.

### Order matters

The SQL layer goes **first** and the application code goes **last**. The new SQL objects are
additive and invisible to the running app until step 8, and the released code depends on
objects that must already exist. Do not deploy the code before step 8.

---

## Step 1 — Preflight (read-only, ~2 minutes)

Run `sql/00_PreflightChecks.sql` against **production**. It changes nothing.

Record the answers to these, because later steps depend on them:

| Check | What you are looking for | If it differs |
|---|---|---|
| CHECK 0 — edition | **Standard.** Confirmed: SQL Server 2022 RTM 16.0.1000.6, `EngineEdition` 2 | The instance is *named* `sqlapp\SQLEXPRESS` but is **not** Express — someone previously read the name as the edition. If a check ever returns `EngineEdition` 4 you are on the wrong instance: real Express has no SQL Agent, and the entire refresh schedule depends on Agent. Also confirm `MachineName` is the **DB** server, not the web server. |
| CHECK 1/2 — do `dbo.MonthlyExpenditure` and `dbo.vw_BudgetAllocation` execute? | **Both succeed** | If either fails with `Invalid object name '…0030ACOAReports'`, the views were never repointed. Fix that first — you need them working as the reconciliation baseline in step 6. |
| Reporting tables | `0030AACOAReports`, `0030ABCOAReportlines`, `0030ACCOAReportAccounts` exist | If only the `0030A*` names exist, production is older than the replica. **Stop** and re-check which is canonical. |
| `varianceLines` row count | 41 rows, 41 **distinct** accounts | If distinct < total, the `INNER JOIN` will fan out and **double money**. Stop. |
| `vw_WebAppUserAccess` equivalent | Rows = distinct `(UserName, ResponsibilityID, DepartmentID)` triples | If rows > distinct, a user holds two positions mapping to one department. The `DISTINCT` in step 2 handles it — but note it, because per-user figures will change versus the legacy views. |

Also record, for step 6 to compare against:

```sql
SELECT FinancialYear, COUNT(*) AS rows_, SUM(CONVERT(decimal(19,4), TotalAllocation)) AS total
FROM dbo.vw_BudgetAllocation
WHERE FinancialYear IN ('2025','2026')
GROUP BY FinancialYear ORDER BY FinancialYear;
```

> ⚠ On the replica this query is fast, but `dbo.MonthlyExpenditure` took **70 seconds for
> `TOP 3`**. Expect the legacy expenditure view to be slow on production too. That is the
> problem being fixed; do not let it alarm you mid-rollout.

---

## Step 2 — Create the ledger objects (~10 seconds)

Apply `sql/FinanceLedger.sql` to `FinanceAutomationSystem`.

It is **idempotent** and **additive**: it creates `vw_WebAppUserAccess`,
`fn_FinanceLedgerSource`, the snapshot tables, `vw_FinanceLedger` and the two refresh procs.
It does **not** touch `dbo.MonthlyExpenditure` or `dbo.vw_BudgetAllocation`. Nothing the
running application reads changes.

Run it in SSMS, or through the repo's PHP runner if `sqlcmd` is unavailable (it is on the
replica — the installed `sqlcmd` is an ODBC 17 build against a Driver 18 install).

Verify:

```sql
SELECT name, type_desc FROM sys.objects
WHERE name IN ('vw_WebAppUserAccess','fn_FinanceLedgerSource','FinanceLedgerSnapshot',
               'FinanceLedgerSnapshot_Staging','FinanceLedgerRefresh','vw_FinanceLedger',
               'usp_RefreshFinanceLedgerSnapshot','usp_RefreshFinanceLedgerSnapshotAll');
-- expect 8 rows
```

---

## Step 3 — Time one fiscal year before committing to the full build

Do **not** skip this. The replica has one active user; production has many, which changes
nothing about the build cost (the build is deliberately unpruned by user) but everything about
how long you should expect the whole loop to take.

```sql
SET STATISTICS TIME ON;
SELECT COUNT(*) FROM dbo.fn_FinanceLedgerSource('2026');
SET STATISTICS TIME OFF;
```

**Replica baseline: 2,203 rows in ~93 seconds.**

| Result | Do this |
|---|---|
| Under ~3 minutes | Proceed to step 4. Full loop ≈ 13 × that. |
| 3–10 minutes | Proceed, but run step 4 out of hours and expect 1–2 hours. |
| Over 10 minutes, or it stalls | **Stop.** Apply the optional index in step 3a, then re-time. |

### Step 3a — Optional index (only if step 3 was slow)

The dominant cost is a full scan of `0098AFinGLMaster` (6,377,713 rows on the replica) whose
only index is the primary key on `LineID`.

```sql
CREATE NONCLUSTERED INDEX IX_0098AFinGLMaster_FinancialYear
    ON dbo.[0098AFinGLMaster] (FinancialYear)
    INCLUDE (TRXDate, AccountNumber, AccountDescription, NetChange);
```

> ⚠ **This writes to a source table this application does not own.** Agree it with whoever
> maintains the GL load before applying — it will slow their inserts slightly and needs to
> survive any table rebuild they perform. It is documented in the footer of
> `sql/FinanceLedger.sql` for exactly this reason.

---

## Step 4 — Build the snapshot (~20 minutes on the replica; longer on production)

Still invisible to users — nothing reads `FinanceLedgerSnapshot` yet.

Start with the two years that matter, so you can reconcile early:

```sql
EXEC dbo.usp_RefreshFinanceLedgerSnapshot @FinancialYear = '2026';
EXEC dbo.usp_RefreshFinanceLedgerSnapshot @FinancialYear = '2025';
```

Then the rest:

```sql
EXEC dbo.usp_RefreshFinanceLedgerSnapshotAll;
```

The `All` proc logs and continues past a failing year, then throws at the end if any failed —
so one bad year does not block the other twelve.

### If a refresh aborts

The sanity gates deliberately refuse to overwrite good data with a suspicious build. On abort
the **previous snapshot is kept** and the reason is recorded:

```sql
SELECT * FROM dbo.FinanceLedgerRefresh ORDER BY FinancialYear;
```

| `Message` says | Meaning | Action |
|---|---|---|
| "Staging is empty" | The source returned nothing | Check the linked server. Do **not** force. |
| "Row count fell from X to Y" | >10% fewer rows than last good load | Investigate. Force only if the drop is genuine. |
| "Total allocation/YTD moved…" | >25% money movement | Normal when a new FY opens or after a bulk reallocation — then force. |

To accept a genuine large movement:

```sql
EXEC dbo.usp_RefreshFinanceLedgerSnapshot @FinancialYear = '2026', @Force = 1;
```

`@Force` never bypasses the zero-row gate.

### Verify the load

```sql
SELECT FinancialYear, RowsLoaded, DurationSeconds, TotalAllocation, TotalYTD, Outcome, Message
FROM dbo.FinanceLedgerRefresh ORDER BY FinancialYear;
```

Every row should read `Outcome = 'OK'`. Expect **zero allocation for FY2014–2024** —
`0040CBudgetsAllocation` holds FY2025 onward only. A negative `TotalYTD` for some years is
possible and can be legitimate (FY2023 on the replica is −117,774,963.13, verified against the
raw GL as genuine credit reversals). Investigate, don't assume a bug.

---

## Step 5 — Sanity-check the ledger before comparing anything

```sql
SELECT TOP 20 * FROM dbo.vw_FinanceLedger WHERE FinancialYear = '2026';
```

Confirm on production, where the replica could not:

- **`ClusterName` is a real cluster**, not a placeholder. The replica's `DBA_Clusters` returns
  `LOCAL TEST CLUSTER` for every row, so **cluster names were never validated** — this is the
  one thing you must eyeball here.
- `InstitutionName`, `ResponsibilityName`, `DepartmentName` are real names.
- `UNDEFINED` appears rarely, if at all. Names fall back
  `RevisedDescription` → `GL40200.DSCRIPTN` → `UNDEFINED`, so a run of `UNDEFINED` means both
  lookups missed and is worth investigating.

```sql
-- how much is unlabelled?
SELECT
    SUM(CASE WHEN ClusterName        = 'UNDEFINED' THEN 1 ELSE 0 END) AS noCluster,
    SUM(CASE WHEN InstitutionName    = 'UNDEFINED' THEN 1 ELSE 0 END) AS noInstitution,
    SUM(CASE WHEN ResponsibilityName = 'UNDEFINED' THEN 1 ELSE 0 END) AS noResponsibility,
    SUM(CASE WHEN DepartmentName     = 'UNDEFINED' THEN 1 ELSE 0 END) AS noDepartment,
    COUNT(*) AS total
FROM dbo.FinanceLedgerSnapshot WHERE FinancialYear = '2026';
```

---

## Step 6 — Reconcile against the legacy views ⚠ THE IMPORTANT STEP

**Do not skip this and do not compare grand totals only.** The `varianceLines` restriction,
`REMOVE` filtering and missing-chart-of-accounts behaviour can each drop one account and inflate
another; offsetting errors cancel in a sum. Compare at **account grain, both directions, first**.

### 6a — Accounts present on one side and absent on the other

```sql
-- In the LEGACY view but NOT the new ledger. Expect ZERO rows.
SELECT o.FinancialYear, o.UserName, o.AccountNumber, o.TotalAllocation
FROM dbo.vw_BudgetAllocation o
WHERE o.FinancialYear IN ('2025','2026')
  AND NOT EXISTS (
      SELECT 1 FROM dbo.vw_FinanceLedger n
      WHERE n.FinancialYear = o.FinancialYear AND n.UserName = o.UserName
        AND n.AccountNumber = o.AccountNumber COLLATE Latin1_General_CI_AS);
```

> **Any row here is a defect. Stop and investigate — do not cut over.**

```sql
-- In the new ledger but NOT the legacy view. Rows are EXPECTED here.
SELECT n.FinancialYear, n.AccountNumber, n.Allocation, n.YTDTotal, n.Approved, n.Routing
FROM dbo.vw_FinanceLedger n
WHERE n.FinancialYear IN ('2025','2026')
  AND NOT EXISTS (
      SELECT 1 FROM dbo.vw_BudgetAllocation o
      WHERE n.FinancialYear = o.FinancialYear AND n.UserName = o.UserName
        AND n.AccountNumber = o.AccountNumber COLLATE Latin1_General_CI_AS);
```

Every row here should have **`Allocation = 0`** — these are the GL- and encumbrance-only
accounts the ledger now carries deliberately. A row here **with a non-zero allocation** is a
defect. Stop.

### 6b — Money, per account, with a tolerance

The sources are `float`, so exact equality is not achievable. Expect **zero rows**.

```sql
SELECT n.FinancialYear, n.AccountNumber, n.Allocation AS newAlloc, o.TotalAllocation AS oldAlloc
FROM dbo.vw_FinanceLedger n
INNER JOIN dbo.vw_BudgetAllocation o
    ON o.FinancialYear = n.FinancialYear AND o.UserName = n.UserName
   AND o.AccountNumber COLLATE Latin1_General_CI_AS = n.AccountNumber
WHERE n.FinancialYear IN ('2025','2026')
  AND ABS(n.Allocation - CONVERT(decimal(19,4), o.TotalAllocation)) > 0.01;
```

### 6c — The TTD 21.1M check, explicitly

This is the defect most likely to survive as a plausible-looking wrong total. Confirm the
allocation-only accounts are **present** in the ledger:

```sql
SELECT COUNT(*) AS allocOnlyAccounts, SUM(a.alloc) AS allocationAtRisk
FROM (
    SELECT AccountNumber, SUM(CONVERT(decimal(19,4), Allocation)) AS alloc
    FROM dbo.[0040CBudgetsAllocation] WHERE FinancialYear = '2026' GROUP BY AccountNumber
) a
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.[0098AFinGLMaster] g
    WHERE g.FinancialYear = '2026' AND g.AccountNumber = a.AccountNumber);
-- Replica: 1,117 accounts / TTD 21,128,414.88

-- Every one of those that is on a reporting-line-3 account MUST be in the snapshot.
-- Expect ZERO rows.
SELECT a.AccountNumber
FROM (SELECT DISTINCT AccountNumber FROM dbo.[0040CBudgetsAllocation] WHERE FinancialYear = '2026') a
INNER JOIN dbo.[0030ACCOAReportAccounts] c
    ON CAST(c.AccountNumber AS varchar(50)) COLLATE Latin1_General_CI_AS
       = SUBSTRING(a.AccountNumber, 3, CHARINDEX('-', a.AccountNumber, 3) - 3) COLLATE Latin1_General_CI_AS
WHERE NOT EXISTS (
    SELECT 1 FROM dbo.FinanceLedgerSnapshot s
    WHERE s.FinancialYear = '2026'
      AND s.AccountNumber = a.AccountNumber COLLATE Latin1_General_CI_AS);
```

### 6d — Monthly expenditure

Slow (the legacy view is the 70-second one). Run it once, for one or two users.

```sql
WITH oldME AS (
    SELECT FinancialYear, AccountNumber, PeriodID,
           SUM(CONVERT(decimal(19,4), NetChange)) AS net
    FROM dbo.MonthlyExpenditure
    WHERE FinancialYear IN ('2025','2026')
    GROUP BY FinancialYear, AccountNumber, PeriodID
),
newME AS (
    SELECT l.FinancialYear, l.AccountNumber, p.PeriodID, SUM(p.net) AS net
    FROM dbo.vw_FinanceLedger l
    CROSS APPLY (VALUES (1,l.[Oct]),(2,l.[Nov]),(3,l.[Dec]),(4,l.[Jan]),(5,l.[Feb]),(6,l.[Mar]),
                        (7,l.[Apr]),(8,l.[May]),(9,l.[Jun]),(10,l.[Jul]),(11,l.[Aug]),(12,l.[Sep])) p(PeriodID,net)
    WHERE l.FinancialYear IN ('2025','2026') AND p.net <> 0
    GROUP BY l.FinancialYear, l.AccountNumber, p.PeriodID
)
SELECT ISNULL(o.FinancialYear, n.FinancialYear) AS fy,
       ISNULL(o.AccountNumber, n.AccountNumber) AS account,
       ISNULL(o.PeriodID, n.PeriodID) AS period,
       o.net AS oldNet, n.net AS newNet
FROM oldME o
FULL OUTER JOIN newME n
    ON o.FinancialYear = n.FinancialYear AND o.PeriodID = n.PeriodID
   AND o.AccountNumber COLLATE Latin1_General_CI_AS = n.AccountNumber COLLATE Latin1_General_CI_AS
WHERE o.net IS NULL OR n.net IS NULL OR ABS(o.net - n.net) > 0.01;
```

**Expected result: only rows where `oldNet` is exactly 0 and `newNet` is NULL.** Those are
months whose transactions net to zero; the new view drops them (`WHERE NetChange <> 0`) because
the snapshot stores every month as 0 and would otherwise emit 12 rows per account. On the
replica that was exactly 3 rows. Anything else is a defect — stop.

---

## Step 7 — Take a rollback note

Before touching the live views, record the current definitions so you can restore them even if
`sp_rename` is somehow unavailable:

```sql
SELECT OBJECT_DEFINITION(OBJECT_ID('dbo.MonthlyExpenditure'))  AS MonthlyExpenditure;
SELECT OBJECT_DEFINITION(OBJECT_ID('dbo.vw_BudgetAllocation')) AS vw_BudgetAllocation;
```

Save both to a file. (This needs `VIEW DEFINITION` permission — granted on the replica; confirm
on production. If it is denied, ask a DBA to script them before proceeding.)

---

## Step 8 — Cut over (seconds)

Apply `sql/FinanceLedgerCutover.sql`.

It refuses to run against an empty snapshot, renames the two live views to `*_Legacy`, and
recreates both names over `vw_FinanceLedger`. The swap is metadata-only.

**This is the first step users can perceive.** Do it during a quiet window.

Verify immediately:

```sql
SELECT TOP 2 * FROM dbo.MonthlyExpenditure  WHERE FinancialYear = '2026';
SELECT TOP 2 * FROM dbo.vw_BudgetAllocation WHERE FinancialYear = '2026';

SELECT FinancialYear, COUNT(*) c, SUM(TotalAllocation) t
FROM dbo.vw_BudgetAllocation GROUP BY FinancialYear ORDER BY FinancialYear;
```

Compare that last result against the figures you recorded in step 1. **They should match.**

Both should now return in well under a second. The old application code still works at this
point — the views kept their names and column lists — so if you stop here the app simply runs
faster.

---

## Step 9 — Deploy the application code

```bash
git pull                    # or your normal deploy
composer install --no-dev --optimize-autoloader
npm ci && npm run build
php artisan config:clear
php artisan cache:clear file    # ⚠ the filter caches live on the `file` store,
                                #    `cache:clear` alone will NOT touch them
```

Confirm Laravel schedules **nothing** — the refresh is a SQL Server Agent job on the DB server:

```bash
php artisan schedule:list
# expect: no scheduled tasks
```

> ⚠ A `ledger:refresh` entry here is a **defect**, not reassurance. Combined with the Agent job it
> double-schedules the same stored procedure, and there is no `sp_getapplock` in the procs to stop
> the collision. Remove it.
>
> **Follow `instructionsforschedule.md` now** to create the Agent job and the health-check task.
> Skip it and the snapshot silently goes stale: no error, no warning, pages keep loading fast and
> the figures just stop moving.

Check `.env` while you are there:

```
APP_TIMEZONE=America/Port_of_Spain
DB_HOST=localhost                    # MySQL, LOCAL to the web server
SQLSRV_HOST=<the DB server>          # SQL Server is on a SEPARATE box — never localhost
```

`DB_HOST` is `mysql` when running under Docker Compose and `localhost` when running natively —
both are correct in their own context, so set it to match production's mode rather than
assuming either value is the "right" one.

`SQLSRV_HOST` is a different matter: production runs the app and SQL Server on **separate Windows
servers**, so it is always the remote box. If a SQL instance happens to also be installed on the
web server, `localhost` there connects to it successfully and reads an empty database — no error,
no data. Step 1b of `instructionsforschedule.md` gates this along with the firewall, ODBC driver
and clock checks the split introduces.

---

## Step 10 — Verify the application

Walk all five pages as a real user with real departmental access:

| Page | Check |
|---|---|
| `/dashboard` | Total budget and YTD figures are plausible; charts render |
| `/budget-allocations` | Row count and total match step 8; FY navigator spans the expected years |
| `/monthly-expenditure` | **Loads fast** (this is the 70s → sub-second fix); month filter works |
| `/department-expenditure` | 12 month columns; future months muted; totals row covers the whole set, not the visible page |
| `/allocation-line-expenditure` | Allocation vs spend; over/under/exact statuses render |

On every page confirm:

- The **same fiscal year shows the same budget total** across Dashboard, Budget Allocations and
  Allocation Line Expenditure.
- Filters cascade and clear correctly; changing fiscal year does not empty the table.
- **A user sees only their own departments.** Log in as two users with different access and
  confirm the row sets differ.

> ⚠ **Expect the Allocation Line Expenditure figures to differ from the old scaffold.** Balance
> and overspend now measure against `ActualExpenditure` (YTD + Approved + Routing), not YTD
> alone — committed money is not available to spend. Brief finance staff on this before rollout;
> it is the one change they will notice and question.

Then run the suite:

```bash
php artisan test
```

Tests needing ledger data **skip** rather than fail when SQL Server is unreachable. If you see
skips mentioning "the ledger snapshot has no rows", the app cannot see the snapshot — check the
connection, not the tests.

---

## Rollback

**Steps 1–7 need no rollback** — nothing the app reads was changed. To undo, drop the new
objects.

**Step 8** (the only user-visible change):

```sql
DROP VIEW dbo.MonthlyExpenditure;
DROP VIEW dbo.vw_BudgetAllocation;
EXEC sp_rename 'dbo.MonthlyExpenditure_Legacy',  'MonthlyExpenditure';
EXEC sp_rename 'dbo.vw_BudgetAllocation_Legacy', 'vw_BudgetAllocation';
```

Seconds to run. The old (slow) behaviour returns.

**Step 9**: redeploy the previous release. Note the old code works against the **new** views
too, so a SQL rollback alone is usually enough — you do not have to roll both back together.

---

## After rollout

1. **Set up the schedule if you have not already** — `instructionsforschedule.md`: the SQL Agent
   job on the DB server, and the health-check task on the web server. Nothing else here matters if
   the refresh never runs.
2. **Confirm the GL load window** and move the refresh if needed. The job runs at 21:30 on the
   assumption that whatever populates `0098AFinGLMaster` runs during the business day. If it runs
   overnight instead, 21:30 reads before it lands and the snapshot sits a full day behind
   permanently — with `RefreshedAt` advancing normally every night, so nothing looks wrong. See
   F1 in `instructionsforschedule.md`; the timing lives in the Agent job now, not
   `routes/console.php`.
3. **Watch the first few scheduled refreshes:**
   ```sql
   SELECT FinancialYear, RefreshedAt, RowsLoaded, DurationSeconds, Outcome, Message
   FROM dbo.FinanceLedgerRefresh ORDER BY RefreshedAt DESC;
   ```
   Anything other than `OK`, or a `RefreshedAt` that stops advancing, means the job is not running.
   Cross-check `msdb.dbo.sysjobhistory` for the reason.
4. **Keep the `_Legacy` views** until production has run on the new ones long enough to trust —
   a full month covering a period close is a reasonable bar. Then:
   ```sql
   DROP VIEW dbo.MonthlyExpenditure_Legacy;
   DROP VIEW dbo.vw_BudgetAllocation_Legacy;
   ```
5. **Delete `sql/MonthlyExpenditureSnapshot.sql`** — superseded. **Keep**
   `sql/GLSegmentLookup_staging.sql`: staging `GL40200` and `DBA_Clusters` locally is the
   mitigation if linked-server flakiness returns.
6. **Confirm any negative fiscal-year totals with finance** (see step 4).

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Pages show "The financial data source is unavailable" | SQL Server unreachable, or the snapshot/views are missing | Check `storage/logs/laravel.log` — controllers log the real exception and only show users the generic message |
| Pages load but every table is empty | Snapshot is empty, or `vw_WebAppUserAccess` returns nothing for that user | `SELECT COUNT(*) FROM dbo.FinanceLedgerSnapshot;` then `SELECT * FROM dbo.vw_WebAppUserAccess WHERE UserName = '…';` |
| A user's figures are exactly **double** | Duplicate `(UserName, ResponsibilityID, DepartmentID)` triples | The view's `DISTINCT` should prevent this. If it happens, check for a modified view |
| Filter dropdowns are stale after a refresh | Version probe cached, or the `file` store was not cleared | Wait 60s (`FINANCE_LEDGER_VERSION_SECONDS`), or `php artisan cache:clear file` |
| Refresh takes far longer than the replica's 90–110s/year | Missing index on `0098AFinGLMaster`, or linked-server latency | Step 3a |
| `Msg 7314 … linked server does not contain the table` | `GPSWRHA.SWRHA.CO.TT` cannot see `GL40200` / `DBA_Clusters` | Check the linked server. Note `GL00100` is **no longer used** — correction (c) removed it |
| Budget total looks far too low | **Not a bug.** Both sources report goods and services only; payroll is excluded by design (41 reporting-line-3 accounts) | See CLAUDE.md. Do not loosen the join to "fix" it |
