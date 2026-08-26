# Oversight Update — Production Runbook

Step-by-step deployment of the Allocation Oversight change (Phase 1). Follow in order.
Companion to `financesqlupdate.md` (the plan and reasoning); this is the doing.

**Two machines, and it matters which you are on:**

| | Machine | What runs there |
|---|---|---|
| **DB** | `sqlapp\SQLEXPRESS` (SQL Server 2022 Standard) | every SSMS step, the Agent job |
| **WEB** | Apache24 box, `C:\php\php.exe` | `php artisan`, `npm run build`, the app |

Steps are tagged **[DB]** or **[WEB]**.

**Time:** ~1 hour, most of it the rebuild in Step 6. Steps 2–8 are all on the DB box except the
cache clear; the WEB box is only needed for Steps 1, 8 and 9. No maintenance window — the ordering
is what makes one unnecessary. **Step 8 is the only moment the RULE changes for users** —
but note Step 6 does move some figures slightly. See the warning in Step 6.

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

> **The script refuses to run twice, and stops dead** (`SET NOEXEC ON`). That is on purpose:
> once Step 5 has been applied, "current state" is post-change, so a second run would capture
> the very code you might need to roll back.
>
> If you do re-run it by accident, you will see `Msg 51210` — **nothing is lost.** The snapshot
> and refresh copies are protected (`SELECT ... INTO` cannot overwrite an existing table). Check
> what the definitions table now holds:
>
> ```sql
> SELECT ObjectName,
>        CASE WHEN Definition LIKE '%0030ADGPCOA%' OR Definition LIKE '%encumbranceShipped%'
>             THEN 'POST-change - use git on rollback' ELSE 'pre-change - fine' END AS state
> FROM dbo.FinanceLedgerDefs_PreOversight ORDER BY ObjectName;
> ```
>
> The **views** are what matter most, and they stay pre-change until Step 8. If the function or
> procs show POST-change, the restore script detects it, refuses, and tells you to apply
> `git show master:sql/FinanceLedger.sql` instead — which restores the old function, both procs
> and the old views in one file.

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

## Step 6 — [DB] Rebuild every fiscal year

> ### This step IS slightly visible to users — the one place this runbook is not silent
>
> It writes to the **production snapshot**, which is what the app reads. Afterwards the app is
> still on the OLD views but over NEW data, so users will see:
>
> - `Approved` down ~5% (a received PO line is no longer double-counted), and because the OLD
>   rule deducts Approved, **balances tick UP slightly**;
> - a few lines possibly flipping from "over" to "under";
> - **Allocation, YTD and access unchanged.**
>
> Small, and in the correct direction — those figures are more accurate than what they replace.
> But it is not nothing, so prefer running this **outside business hours**: someone refreshing a
> page mid-rebuild can watch a year's figures move as that year completes.
>
> The swap is transactional per year, so nobody ever sees a half-loaded year.

In SSMS, against `FinanceAutomationSystem`:

```sql
EXEC dbo.usp_RefreshFinanceLedgerSnapshotAll;
```

**Run it here rather than from the web box.** `php artisan ledger:refresh --all` is a thin
wrapper around this exact statement and adds no logic of its own, but running it in SSMS is
better in three ways:

- **You see progress.** The proc reports a failing year via `PRINT`, and `--all` uses
  Laravel's `->statement()`, which discards result sets — so those messages go nowhere through
  PHP. In SSMS they appear live in the Messages tab.
- **No network timeout.** The web box talks to `sqlapp\SQLEXPRESS` across the network and this
  is a single ~45-minute statement. `config/ledger.php` notes `timeout_seconds` is *retained
  but unused*, so nothing in the app guards it — you would be trusting the ODBC driver and the
  network not to drop a long call. SSMS on the DB server is local.
- **One less machine in the loop** during the longest step.

Budget ~43 minutes; it should be faster now the linked server is gone (~22s per year on the dev
replica, but **measure it here — that is the number that matters**).

> **The proc continues past a failing year** and throws only at the end, so a `THROW` at the
> finish means "one or more years failed", not "nothing worked". Years that succeeded are
> committed and fine. The verification query below is what actually tells you which.

If you would rather have per-year timings as you go, run them one at a time instead — each call
returns rows, duration and totals:

```sql
EXEC dbo.usp_RefreshFinanceLedgerSnapshot @FinancialYear = '2026';
EXEC dbo.usp_RefreshFinanceLedgerSnapshot @FinancialYear = '2025';
-- ... and so on for each year present in the source
```

**Watch the clock and the waits.** If a year takes far longer than the rest, open a SECOND SSMS
window and capture what it is waiting on before assuming it is stuck:

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

Everything so far is reversible by restoring the backup, and **the balance rule and access
scoping are not live yet** — only the encumbrance figures have moved (Step 6). Check properly
before continuing: this is the last point where reverting costs nothing but a restore.

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
WHERE s.FinancialYear = '2026'      -- MUST match the Step 4 baseline, which is
                                    -- filtered to the current FY. Without this
                                    -- you count all 13 years and the "after"
                                    -- figure comes out ~4x the "before" - an
                                    -- apples-to-oranges comparison that looks
                                    -- like a catastrophic failure. Update the
                                    -- year when the fiscal year rolls over.
GROUP BY ua.UserName ORDER BY ua.UserName;
```

> **Sanity anchor.** On the 2026-08-25 data the one mapped user went from
> **2,070 accounts / TTD 227,404,246.21** to **831 / TTD 128,258,284.14**. If your "after" is in
> that neighbourhood, this is working. If it is *unchanged* from the baseline, the three-way join
> is not filtering — stop and investigate before the cutover.

Compare against the Step 4 access baseline:

- **No user may rise.** Institution scoping can only narrow.
- **No user may drop to zero.** That is a rollback trigger.
- A large drop is **expected and correct** — dev measured −60% of rows and −44% of allocation.

**If any of this looks wrong, stop here.** The balance rule and the access scoping have NOT
changed yet — only the underlying encumbrance figures (see Step 6). Restore with
`sql/FinanceLedgerOversightRestore.sql`, re-enable the Agent job, and users are back to exactly
what they had. Nothing else is needed.

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

**Before Step 8** — the rule and the access scoping are untouched; only the snapshot's
encumbrance figures moved (Step 6). Run `sql/FinanceLedgerOversightRestore.sql`, re-enable the
Agent job, done. No application deploy to undo.

**After Step 8:**

1. **[DB]** Run `sql/FinanceLedgerOversightRestore.sql` — views first (in one transaction), then
   function and procs, then the data.
   - If it throws **`51223`**, the captured function/procs are post-change (see Step 4). The views
     have already been restored. Apply `git show master:sql/FinanceLedger.sql` to put the old
     function and procs back, then re-run the restore script for the data.
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
| 6 | DB | `EXEC usp_RefreshFinanceLedgerSnapshotAll` | yes — restore backup. **Slightly visible** — see Step 6 |
| 7 | DB | **reconcile — go/no-go** | last free exit |
| 8 | DB+WEB | **cutover — users see this** | yes, via restore script |
| 9 | WEB | verify in app | — |
| 10 | DB | re-enable Agent job | — |
| 11 | — | merge; drop backups later | — |
