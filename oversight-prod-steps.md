# Oversight Update — Production Runbook

Step-by-step deployment of the Allocation Oversight change (Phase 1). Follow in order.
Companion to `financesqlupdate.md` (the plan and reasoning); this is the doing.

**Two machines, and it matters which you are on:**

| | Machine | What runs there |
|---|---|---|
| **DB** | `sqlapp\SQLEXPRESS` (SQL Server 2022 Standard) | every SSMS step, the Agent job |
| **WEB** | Apache24 box, `C:\php\php.exe` | `php artisan`, `npm run build`, the app |

Steps are tagged **[DB]** or **[WEB]**.

**Time:** ~1 hour, most of it the rebuild in Step 6. No maintenance window — the ordering
is what makes one unnecessary. Steps 1–7 are invisible to users; **Step 8 is the only
moment anything changes for them.**

---

## Before you start — three things that are not code

1. **Name the rollback owner.** One person who decides to revert. Write the name here: `________`
2. **Tell the finance team what will change**, before they see it. Two numbers move visibly:
   - **The "over" count on Allocation Line Expenditure will fall**, possibly to zero, and
     balances will rise. Approved and Routing no longer push a line over budget.
   - **Page totals for the affected user will drop by roughly 44%.** That is the
     cross-institution exposure being closed, not data going missing.
3. **Pick your moment.** No window is needed, but during Step 6 a user reloading a page may
   see a year's encumbrance figures shift as that year completes. Evening is kinder.

---

## Step 1 — [WEB] Get the code onto the server

```powershell
cd C:\path\to\finance
git fetch origin
git checkout feature/ledger-oversight-update
git pull
npm ci
npm run build          # public/build is gitignored - it MUST be built here
```

Do **not** deploy the frontend yet if your deploy is a separate step — Step 8 is where it goes
live. If `git checkout` swaps the built assets in place, that is fine: the old Vue page reads
`totals.encumbered`, which the old controller still supplies until Step 8.

---

## Step 2 — [DB] Preflight checks — the go/no-go for the whole release

Open `sql/00_PreflightChecks.sql` in SSMS against **`FinanceAutomationSystem`** and run
**CHECKs 12–20** (at the end of the file).

A restored backup is never authoritative for a live release — the `InstitutionID` column in
CHECK 18 appeared between two backups taken three weeks apart. Run these against **live
production**, now.

| Check | Must be | If not |
|---|---|---|
| 12 · COA grain | `duplicates = 0` | **STOP.** The COA join would multiply every money column. |
| 13 · Correction grain | `conflicts = 0` | **STOP.** Agree a tie-break with finance first. |
| 14 · Label coverage | all `blank_*` = 0 | **STOP.** The COA mirror is stale or truncated. |
| 15 · Segment ambiguity | all three = 0 | **STOP.** The label fallback is unsafe. |
| 16 · Shipment conversion | both = 0 | **STOP.** Fix the source rows; do not skip them. |
| 17 · Shipment key | `intersecting_open_encumbrance = 0` | **STOP.** Two GP lines would be summed as one. |
| **18 · InstitutionID** | exists, `blank_institution = 0` | **STOP — FAIL THE RELEASE.** See below. |
| 19 · Cross-institution | *record it* (expect ~32 of 128) | informational |
| 20 · Unmatched grants | *record it* (expect ~15) | informational — the baseline for later |

**On CHECK 18 specifically:** if `InstitutionID` is absent or blank, do **not** work around it.
There is no fallback to the two-way join, deliberately — that rule exposes other institutions'
money. Stop, and ask the finance team to populate the column.

**Write down** the CHECK 19 and 20 numbers. You compare against them in Step 9.

---

## Step 3 — [DB] Stop the Agent job

```sql
EXEC msdb.dbo.sp_update_job @job_name = N'SWRHA Finance - Ledger Refresh', @enabled = 0;

-- confirm it is not running RIGHT NOW
SELECT j.name, ja.start_execution_date, ja.stop_execution_date
FROM msdb.dbo.sysjobactivity ja
JOIN msdb.dbo.sysjobs j ON j.job_id = ja.job_id
WHERE j.name = N'SWRHA Finance - Ledger Refresh'
  AND ja.start_execution_date IS NOT NULL AND ja.stop_execution_date IS NULL;
```

The second query must return **no rows**. This is mandatory, not hygiene: the refresh procs
have no `sp_getapplock`, so nothing at the SQL layer stops the 21:30 job colliding with your
manual rebuild.

If it *is* running, wait for it to finish. Do not kill it mid-swap.

---

## Step 4 — [DB] Back up

```
Run: sql/FinanceLedgerOversightBackup.sql
```

It preserves the snapshot, the refresh metadata, and the CREATE text of all seven objects, then
refuses to continue if any of that failed.

**Save the two result sets it prints.** They are the per-FY baseline and the per-user access
baseline — the restore is verified against them, and Step 7 compares against them.

> The script refuses to run twice. That is on purpose: re-running it after a cutover would
> overwrite the pre-change copy with post-change data and destroy the way back.

---

## Step 5 — [DB] Apply the prepare stage

```
Run: sql/FinanceLedger.sql
```

Installs the rewritten function, the snapshot tables, the three additive metadata columns, and
both refresh procs with their new gates. It is idempotent.

**This does not create the two views** — that is Step 8, on purpose. So right now:

- the app still serves the **old** balance rule and the **old** access rule;
- nothing users can see has changed;
- the new logic is staged and ready.

Sanity check it took:

```sql
SELECT name, TYPE_NAME(user_type_id) FROM sys.columns
WHERE object_id = OBJECT_ID('dbo.FinanceLedgerRefresh')
  AND name IN ('TotalApproved','TotalRouting','UndefinedLabelPct');   -- expect 3 rows
```

---

## Step 6 — [WEB] Rebuild every fiscal year

```powershell
php artisan ledger:refresh --all
```

Budget ~43 minutes; it should be faster now the linked server is gone (~22s per year on the dev
replica, but **measure it here — that is the number that matters**).

**Watch the clock and the waits.** If a year takes far longer than the rest, capture what it is
waiting on before assuming it is stuck:

```sql
SELECT session_id, status, wait_type, wait_time, cpu_time, total_elapsed_time
FROM sys.dm_exec_requests WHERE session_id <> @@SPID AND status <> 'sleeping';
```

A `CXSYNC_PORT` wait with near-zero `cpu_time` is a parallelism stall — the dev box has one, and
if production shows the same, raise it with the DBA as a **separate** piece of work. Do not add
MAXDOP hints to this application's SQL.

**If a gate fires, read the message — it names the problem.** Do not reflexively re-run with
`--force`. None of Allocation, YTD or the row count should move, so a gate firing is
information.

Then confirm **every** year succeeded — the "all" proc continues past a failing year and throws
only at the end, so a partial success is easy to miss:

```sql
SELECT FinancialYear, Outcome, RowsLoaded, RefreshedAt, Message
FROM dbo.FinanceLedgerRefresh ORDER BY FinancialYear DESC;
```

No row may read `ABORTED`.

---

## Step 7 — [DB] Reconcile — this is the go/no-go point

Everything so far is reversible by restoring the backup, and **the user-visible rule is not live
yet**. Check properly before continuing.

```sql
-- A. money: compare against the Step 4 baseline
SELECT FinancialYear, COUNT(*) AS accounts,
       CONVERT(decimal(19,2), SUM(Allocation)) AS allocation,
       CONVERT(decimal(19,2), SUM(YTDTotal))   AS ytd,
       CONVERT(decimal(19,2), SUM(Approved))   AS approved,
       CONVERT(decimal(19,2), SUM(Routing))    AS routing,
       CONVERT(decimal(5,2), 100.0 * SUM(CASE WHEN DepartmentName = 'UNDEFINED' THEN 1 ELSE 0 END) / COUNT(*)) AS undefined_pct
FROM dbo.FinanceLedgerSnapshot GROUP BY FinancialYear ORDER BY FinancialYear DESC;
```

| Column | Expected |
|---|---|
| `accounts`, `allocation`, `ytd` | **unchanged from Step 4.** Any movement = stop and investigate |
| `approved` | **down a few percent** (dev measured −5.0%) |
| `routing` | essentially unchanged (cents, from float→decimal) |
| `undefined_pct` | near zero, and not a jump |

```sql
-- B. access: what Step 8 will actually do, measured BEFORE it happens
WITH ua AS (
    SELECT DISTINCT LTRIM(RTRIM(U.UserName)) AS UserName,
        UPPER(LTRIM(RTRIM(P.InstitutionID)))    COLLATE Latin1_General_CI_AS AS I,
        UPPER(LTRIM(RTRIM(P.ResponsibilityID))) COLLATE Latin1_General_CI_AS AS R,
        UPPER(LTRIM(RTRIM(P.DepartmentID)))     COLLATE Latin1_General_CI_AS AS D
    FROM [SWRHAExpenseControl].[dbo].[0006AWebAppControls] U
    JOIN [SWRHAExpenseControl].[dbo].[0006CWebAppPostControls] P ON U.PositionID = P.PositionID
    WHERE U.IsActive = 'TRUE' AND P.IsActive = 'TRUE'
)
SELECT ua.UserName, COUNT(*) AS accounts_after,
       CONVERT(decimal(19,2), SUM(s.Allocation)) AS allocation_after
FROM dbo.FinanceLedgerSnapshot s
JOIN ua ON ua.I = s.InstitutionID AND ua.R = s.ResponsibilityID AND ua.D = s.DepartmentID
GROUP BY ua.UserName ORDER BY ua.UserName;
```

Compare against the Step 4 access baseline:

- **No user may rise.** Institution scoping can only narrow.
- **No user may drop to zero.** That is a rollback trigger.
- A large drop is **expected and correct** — dev measured −60% of rows and −44% of allocation.

**If any of this looks wrong, stop here.** You have changed nothing users can see. Restore with
`sql/FinanceLedgerOversightRestore.sql` and nothing else is needed.

---

## Step 8 — The cutover — the only user-visible moment

Do these two together, back to back.

**[DB]**
```
Run: sql/FinanceLedgerOversightCutover.sql
```

Applies both views in **one transaction**, behind guards. It prints three verifications — read
them:

| Verification | Must be |
|---|---|
| accessible accounts by user | non-zero for every user |
| **FAN-OUT alert** | **no rows** — any row means money is doubling |
| balance rule | all four counters `0` |

**[WEB]** — immediately after:
```powershell
php artisan cache:clear file
```

Filter lists are versioned by the snapshot's refresh time so they invalidate themselves, but
clear anyway. If your frontend deploy is separate from Step 1, do it now.

---

## Step 9 — [WEB] Verify in the app

Log in as a user who **has** mappings. **Do not use `FFIGUERA1`** — as of 2026-08-25 that
account has no mappings at all and will correctly show empty pages. Check
`SELECT UserName, COUNT(*) FROM dbo.vw_WebAppUserAccess GROUP BY UserName` for who to use.

**Allocation Line Expenditure** — the page this change is about:
- Columns read: Allocation · 12 months · YTD Expenditure · Approved · Routing · YTD + Approved · Balance of Allocation · Status
- **`Allocation − YTD Expenditure` equals `Balance of Allocation`** on every under-spent row
- Routing is visible and affects nothing
- Hovering "Balance of Allocation" shows the tooltip explaining that
- The totals row sums the whole filtered set, not just the visible page

**Dashboard, Budget Allocations, Monthly Expenditure, Department Expenditure** — regression only.
Totals may legitimately be lower where institution scoping narrowed access. Account descriptions
will read differently (curated corrections) — spot-check they are better, not blank.

Switch fiscal years, apply and clear filters.

**[WEB]** health check:
```powershell
php artisan ledger:status     # must exit 0
```

---

## Step 10 — [DB] Re-enable the Agent job

```sql
EXEC msdb.dbo.sp_update_job @job_name = N'SWRHA Finance - Ledger Refresh', @enabled = 1;
```

**Do not skip this.** Miss it and the snapshot silently stops refreshing — the failure mode
`ledger:status` exists to catch. Confirm tomorrow that the 21:30 run completed.

---

## Step 11 — Merge, and clean up later

```powershell
git checkout master
git merge feature/ledger-oversight-update
```

**Leave the `_PreOversight` tables alone** until the change has been accepted — at least one
period close. Then:

```sql
DROP TABLE dbo.FinanceLedgerSnapshot_PreOversight;
DROP TABLE dbo.FinanceLedgerRefresh_PreOversight;
DROP TABLE dbo.FinanceLedgerDefs_PreOversight;
```

After that drop, `FinanceLedgerOversightRestore.sql` can no longer restore anything.

---

## If it goes wrong

**Before Step 8** — nothing users can see has changed. Run
`sql/FinanceLedgerOversightRestore.sql`, re-enable the Agent job, done.

**After Step 8:**

1. **[DB]** Run `sql/FinanceLedgerOversightRestore.sql` — views first (in one transaction), then
   function and procs, then the data.
2. **[WEB]** `git checkout master` → `npm ci` → `npm run build` → `php artisan cache:clear file`
3. **[DB]** Re-enable the Agent job.
4. Verify against the Step 4 baseline — the script prints the comparison and a fan-out check.

**Roll back if any of these:**
- an active user's accessible account count drops to **zero** (a large *reduction* is expected);
- snapshot Allocation, YTD or account count moved at all;
- `UNDEFINED` label share jumped;
- Approved/Routing movement you cannot attribute to shipment netting.

> **Never use `sql/FinanceLedgerRollback.sql` for this.** That script drops the entire ledger
> subsystem — every view, both procs, the function and all three tables. It is the undo for the
> original migration, not for this revision.

---

## Quick reference

| Step | Where | Action | Reversible? |
|---|---|---|---|
| 1 | WEB | checkout + build | yes |
| 2 | DB | preflight CHECKs 12–20 | read-only |
| 3 | DB | disable Agent job | yes |
| 4 | DB | backup | read-only |
| 5 | DB | `FinanceLedger.sql` | yes — invisible to users |
| 6 | WEB | `ledger:refresh --all` | yes — restore backup |
| 7 | DB | **reconcile — go/no-go** | last free exit |
| 8 | DB+WEB | **cutover — users see this** | yes, via restore script |
| 9 | WEB | verify in app | — |
| 10 | DB | re-enable Agent job | — |
| 11 | — | merge; drop backups later | — |
