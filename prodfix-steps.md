# Production Steps — Manual Runbook

Copy-paste steps to take the finance ledger live on production.

Run everything in **SSMS**, connected to `sqlapp\SQLEXPRESS`, database **`FinanceAutomationSystem`**.
`sqlcmd` on the workstation is broken (ODBC 17 build against a Driver 18 install).

**You need a login that can create objects.** The application login `finance` cannot — it is
read-only on DDL.

Plan and rationale: `prodfix.md`. What has been built and verified: `prodfixprogress.md`.

> **This exact SQL is already deployed and working on dev** (`V165ICTFA0MEL\SQLEXPRESS`): all
> objects created, 13 fiscal years built, refresh proc verified at 114s for FY2026, all five pages
> rendering, test suite 36 passed / 3 skipped. Production is the same script against real data.

---

## Before you start

| | |
|---|---|
| Total time | ~1–1.5 hours, most of it the snapshot build running unattended |
| User-visible impact | **None until Step 6.** Steps 1–5 are additive and invisible |
| Reversible | Yes — Step 6 undoes in seconds, Steps 1–5 by dropping the objects (Appendix A) |
| Best window | Out of hours. Step 3 puts ~40–55 minutes of sustained load on a box that also serves live Access users |

---

## Step 1 — Create the objects (~10 seconds)

Open and execute **`sql/FinanceLedger.sql`**.

Creates: `vw_WebAppUserAccess`, `fn_FinanceLedgerSource`, `FinanceLedgerSnapshot` (+ `_Staging`),
`FinanceLedgerRefresh`, `vw_FinanceLedger`, and the two refresh procs. Idempotent — safe to re-run.

**Nothing reads these yet.** The two live views are untouched.

Verify — expect **8 rows**:

```sql
SELECT name, type_desc FROM sys.objects
WHERE name IN ('vw_WebAppUserAccess','fn_FinanceLedgerSource','FinanceLedgerSnapshot',
               'FinanceLedgerSnapshot_Staging','FinanceLedgerRefresh','vw_FinanceLedger',
               'usp_RefreshFinanceLedgerSnapshot','usp_RefreshFinanceLedgerSnapshotAll')
ORDER BY name;
```

---

## Step 2 — Build ONE year and time it

Do not go straight to all 13. This tells you what the full loop will cost.

```sql
EXEC dbo.usp_RefreshFinanceLedgerSnapshot @FinancialYear = '2026';
```

Returns one row: `FinancialYear, RowsLoaded, DurationSeconds, TotalAllocation, TotalYTD`.

**MEASURED ON PRODUCTION 2026-08-03 (FY2026):**

| | Production | Dev |
|---|---|---|
| RowsLoaded | **2,203** | 2,203 |
| DurationSeconds | **243** | 114 |
| TotalAllocation | **242,817,848.5200** | 242,817,848.5200 |
| TotalYTD | **213,334,810.4100** | 213,334,810.4100 |

The money matching dev to the cent is the real check — dev is a replica, so identical figures are
what a correct build produces, and exactly what you would NOT get if the account base, the
reporting-line restriction or the float handling were wrong.

| Result | Do this |
|---|---|
| ~2,200 rows and the totals above | Continue to Step 3 |
| Under ~5 minutes | Fine. Production ran 243s; dev 114s |
| Over 10 minutes, or it errors | **Stop.** Report the timing and message |
| `RowsLoaded` far from ~2,200 | **Stop.** The account base is wrong — duration is irrelevant |

**Record TotalAllocation.** You compare it against the post-cutover check in Step 6.

---

## Step 3 — Build the remaining years (~40–55 minutes)

```sql
EXEC dbo.usp_RefreshFinanceLedgerSnapshotAll;
```

Logs and continues past a failing year, then throws at the end if any failed.

Verify — every row should read `Outcome = 'OK'`:

```sql
SELECT FinancialYear, RefreshedAt, RowsLoaded, DurationSeconds,
       TotalAllocation, TotalYTD, Outcome, Message
FROM dbo.FinanceLedgerRefresh
ORDER BY FinancialYear;
```

**Expected oddities that are NOT errors:**

- **FY2014–2024 show `TotalAllocation = 0`.** `0040CBudgetsAllocation` only holds FY2025 onward.
- **FY2023 shows a large negative `TotalYTD`** (about −117,774,963). Verified against the raw GL as
  genuine credit reversals concentrated on responsibility 401 / department 0627. Worth confirming
  with finance, but it is not a bug.

If a year reads `ABORTED`, the `Message` says why and **the previous snapshot was kept**. See
Appendix B.

Quick read-speed check — should be well under a second:

```sql
SELECT COUNT(*) FROM dbo.vw_FinanceLedger WHERE FinancialYear = '2026';
```

---

## Step 4 — Reconcile (do not skip)

Compare at **account grain, both directions**. A matching grand total proves nothing: the
reporting-line restriction and missing-chart-of-accounts behaviour can each drop one account and
inflate another, and offsetting errors cancel in a sum.

```sql
-- 4a. In the LEGACY view but NOT the new ledger.  EXPECT: ZERO ROWS.
SELECT o.FinancialYear, o.UserName, o.AccountNumber, o.TotalAllocation
FROM dbo.vw_BudgetAllocation o
WHERE o.FinancialYear IN ('2025','2026')
  AND NOT EXISTS (
      SELECT 1 FROM dbo.vw_FinanceLedger n
      WHERE n.FinancialYear = o.FinancialYear AND n.UserName = o.UserName
        AND n.AccountNumber = o.AccountNumber COLLATE Latin1_General_CI_AS);
```

> **Any row here is a defect. STOP — do not cut over.**

```sql
-- 4b. In the new ledger but NOT the legacy view. Rows ARE expected here.
--     EVERY row must have Allocation = 0 (GL- or encumbrance-only accounts).
SELECT n.FinancialYear, n.AccountNumber, n.Allocation, n.YTDTotal, n.Approved, n.Routing
FROM dbo.vw_FinanceLedger n
WHERE n.FinancialYear IN ('2025','2026')
  AND NOT EXISTS (
      SELECT 1 FROM dbo.vw_BudgetAllocation o
      WHERE n.FinancialYear = o.FinancialYear AND n.UserName = o.UserName
        AND n.AccountNumber = o.AccountNumber COLLATE Latin1_General_CI_AS);
```

> A row here **with a non-zero Allocation is a defect. STOP.**

```sql
-- 4c. Money per account, with tolerance (sources are float).  EXPECT: ZERO ROWS.
SELECT n.FinancialYear, n.AccountNumber, n.Allocation AS newAlloc, o.TotalAllocation AS oldAlloc
FROM dbo.vw_FinanceLedger n
INNER JOIN dbo.vw_BudgetAllocation o
    ON o.FinancialYear = n.FinancialYear AND o.UserName = n.UserName
   AND o.AccountNumber COLLATE Latin1_General_CI_AS = n.AccountNumber
WHERE n.FinancialYear IN ('2025','2026')
  AND ABS(n.Allocation - CONVERT(decimal(19,4), o.TotalAllocation)) > 0.01;
```

```sql
-- 4d. The TTD 21.1M check. The allocation-only accounts MUST be present.
--     EXPECT: ZERO ROWS from the second query.
SELECT COUNT(*) AS allocOnlyAccounts, SUM(a.alloc) AS allocationAtRisk
FROM (SELECT AccountNumber, SUM(CONVERT(decimal(19,4), Allocation)) AS alloc
      FROM dbo.[0040CBudgetsAllocation] WHERE FinancialYear='2026' GROUP BY AccountNumber) a
WHERE NOT EXISTS (SELECT 1 FROM dbo.[0098AFinGLMaster] g
                  WHERE g.FinancialYear='2026' AND g.AccountNumber = a.AccountNumber);
-- dev showed 1,117 accounts / TTD 21,128,414.88

SELECT a.AccountNumber
FROM (SELECT DISTINCT AccountNumber FROM dbo.[0040CBudgetsAllocation] WHERE FinancialYear='2026') a
INNER JOIN dbo.[0030ACCOAReportAccounts] c
    ON CAST(c.AccountNumber AS varchar(50)) COLLATE Latin1_General_CI_AS
       = SUBSTRING(a.AccountNumber, 3, CHARINDEX('-', a.AccountNumber, 3) - 3) COLLATE Latin1_General_CI_AS
WHERE NOT EXISTS (SELECT 1 FROM dbo.FinanceLedgerSnapshot s
                  WHERE s.FinancialYear='2026'
                    AND s.AccountNumber = a.AccountNumber COLLATE Latin1_General_CI_AS);
```

```sql
-- 4e. Monthly figures vs the legacy view.
--     SLOW: the legacy MonthlyExpenditure takes ~80s on production. Run it once.
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
SELECT ISNULL(o.FinancialYear,n.FinancialYear) fy,
       ISNULL(o.AccountNumber,n.AccountNumber) account,
       ISNULL(o.PeriodID,n.PeriodID) period, o.net AS oldNet, n.net AS newNet
FROM oldME o
FULL OUTER JOIN newME n
    ON o.FinancialYear = n.FinancialYear AND o.PeriodID = n.PeriodID
   AND o.AccountNumber COLLATE Latin1_General_CI_AS = n.AccountNumber COLLATE Latin1_General_CI_AS
WHERE o.net IS NULL OR n.net IS NULL OR ABS(o.net - n.net) > 0.01;
```

**Expected: only rows where `oldNet` is exactly 0 and `newNet` is NULL.** Those are months netting
to zero, which the new view drops. On dev that was exactly 3 rows. **Anything else — STOP.**

---

## Step 5 — Validate names (only possible on production)

Dev returns `LOCAL TEST CLUSTER` for every row, so cluster names have **never** been checked.
Production has 53 real clusters and 418 real segments. **This is the one check dev could not do.**

```sql
SELECT TOP 20 AccountNumber, AccountDescription, ClusterName,
       InstitutionName, ResponsibilityName, DepartmentName
FROM dbo.vw_FinanceLedger WHERE FinancialYear = '2026';

-- How much is unlabelled? A run of UNDEFINED means both name lookups missed.
SELECT
    SUM(CASE WHEN ClusterName        = 'UNDEFINED' THEN 1 ELSE 0 END) AS noCluster,
    SUM(CASE WHEN InstitutionName    = 'UNDEFINED' THEN 1 ELSE 0 END) AS noInstitution,
    SUM(CASE WHEN ResponsibilityName = 'UNDEFINED' THEN 1 ELSE 0 END) AS noResponsibility,
    SUM(CASE WHEN DepartmentName     = 'UNDEFINED' THEN 1 ELSE 0 END) AS noDepartment,
    COUNT(*) AS total
FROM dbo.FinanceLedgerSnapshot WHERE FinancialYear = '2026';
```

**Eyeball that cluster names are real.**

---

## Step 6 — Cutover ⚠ first user-visible step

Only proceed if Steps 4 and 5 passed.

Execute **`sql/FinanceLedgerCutover.sql`**. It refuses to run against an empty snapshot, renames
the two live views to `_Legacy`, and recreates them over `vw_FinanceLedger`. Metadata-only, seconds.

Verify immediately — both should now return in well under a second:

```sql
SELECT TOP 2 * FROM dbo.MonthlyExpenditure  WHERE FinancialYear = '2026';
SELECT TOP 2 * FROM dbo.vw_BudgetAllocation WHERE FinancialYear = '2026';

SELECT FinancialYear, COUNT(*) c, SUM(TotalAllocation) t
FROM dbo.vw_BudgetAllocation GROUP BY FinancialYear ORDER BY FinancialYear;
```

**Compare that last result against what you recorded in Step 4.** The figures must match.

Keep the `_Legacy` views until production has run on the new ones through at least one period
close.

---

## Appendix A — Undo

**See `prodfix-steps-undo.md`** — a standalone runbook for reversing this rollout.

In short, using `sql/FinanceLedgerRollback.sql`:

| Situation | Flags | Time |
|---|---|---|
| Wrong after cutover — get back to how it was | `@RestoreLegacyViews = 1`, `@DropLedgerObjects = 0` | seconds, **no rebuild** |
| Abandoning the work entirely | both `= 1` | seconds, 16-38 min to return |

Do **not** hand-write the drops: after cutover the live views are defined over
`dbo.vw_FinanceLedger`, so the wrong order breaks both pages and destroys the only copy of the
original definitions. The script enforces the order and refuses the unsafe case.

---

## Appendix B — When a refresh aborts

The sanity gates refuse to overwrite good data with a suspicious build. On abort the **previous
snapshot is kept** and the reason is recorded in `dbo.FinanceLedgerRefresh.Message`.

| Message | Meaning | Action |
|---|---|---|
| "Staging is empty" | Source returned nothing — usually the linked server | Check `GPSWRHA.SWRHA.CO.TT`. **Do not force** |
| "Row count fell from X to Y" | >10% fewer rows than the last good load | Investigate first |
| "Total allocation/YTD moved…" | >25% movement — normal when a new FY opens or after a bulk reallocation | Force if genuine |

```sql
EXEC dbo.usp_RefreshFinanceLedgerSnapshot @FinancialYear = '2026', @Force = 1;
```

`@Force` bypasses the movement gates only. It never bypasses the zero-row gate.

---

## After the cutover

- **Deploy the application.** The current working tree needs `vw_FinanceLedger` to exist, which
  Step 1 provides.
- **Set up the scheduler** — `instructionsforschedule.md`. Two Windows Task Scheduler tasks
  (`SWRHA Finance - Scheduler` and `- Ledger Health Check`), **no queue worker**.
  Set `FINANCE_LEDGER_REFRESH_TIMEOUT` to at least double whatever Step 3 actually took; the
  default is now 7200.
- **Move the daily refresh** to just after the GL load into `0098AFinGLMaster` — still the one
  outstanding unknown.
