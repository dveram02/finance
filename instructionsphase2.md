# Phase 2 — Production Runbook (Requisition detail data layer)

Step-by-step deployment of the requisition-line detail snapshot. Follow in order.
Companion to `financesqlupdatep2.md` (the plan, the reasoning and the as-built record); this is
the doing. Progress log for all phases: `financesqlupdateprogress.md`.

**Two machines, and it matters which you are on:**

| | Machine | What runs there |
|---|---|---|
| **DB** | `sqlapp\SQLEXPRESS` (SQL Server 2022 Standard) | every SSMS step, the Agent job |
| **WEB** | Apache24 box, `C:\php\php.exe` | `php artisan`, the app |

Steps are tagged **[DB]** or **[WEB]**.

**Time:** ~20 minutes, and most of that is reading output. The build itself measured 11–14s.

---

## What makes this release different from Phase 1

Read this before planning a window, because the shape of the risk is not the same.

* **There is NO user-visible moment.** Nothing in the application reads these objects. The pages
  that consume them are Phase 3 and do not exist. A user cannot tell this deployment happened.
* **It is purely ADDITIVE.** Every object is new and owned by this project. No existing table,
  view, function or procedure is modified — **with exactly one exception**, Step 7a, which changes
  the Agent job's step 1 from *quit reporting success* to *go to the next step*.
* **Rollback is genuinely cheap.** Phase 1 needed a backup script, a restore script and a
  transactional cutover because it replaced views a live app was reading. Here, dropping
  everything leaves Phase 1 working exactly as it does today.
* **No maintenance window is needed.** The rebuild in Step 4 writes only to new tables.

**The one behaviour change to warn people about:** after Step 7a, if the requisition step fails,
the **whole job reports failure** where previously it reported success. The ledger will still have
refreshed correctly. A red job after this release does not mean the ledger is broken — read which
step failed before reacting.

---

## Before you start — three things that are not code

1. **Name the rollback owner.** One person who decides to revert. Write the name here: `________`
2. **Confirm Phase 1 is healthy right now.** This release reconciles against
   `dbo.FinanceLedgerSnapshot`. If the ledger is stale or a year is ABORTED, fix that first —
   otherwise Step 4 may abort for a reason that has nothing to do with Phase 2.
   ```powershell
   C:\php\php.exe artisan ledger:status
   ```
   Must exit 0. If it does not, **stop and resolve Phase 1 first.**
3. **You need an admin login on the DB box.** Steps 2b, 6 and 7 touch `msdb` and grants. The app
   login (`finance`) cannot do them.

---

## Step 1 — [WEB] Deploy the application code FIRST

**Order matters, and this is the reason.** The new `ledger:status` reads both refresh logs and
asserts they come from the same run — that assertion is the *only* thing that can see a
step-2-only failure. Step 7 is what creates that failure mode, so the monitoring must already be
in place before you get there.

Deploying the app code first is safe: with the Phase 2 tables absent, `ledger:status` reports
`Requisition detail: not configured on this database.` as a **note**, keeps checking ledger
freshness, and still exits 0.

```powershell
cd C:\Apache24\htdocs\production\finance-automation-system
git fetch origin
git checkout feature/ledger-oversight-update
git pull
php artisan config:clear
```

**No `npm run build`.** Phase 2 changes no frontend file. If your process always builds, it is
harmless — just not required.

Confirm the two commands exist and the health check still passes:

```powershell
C:\php\php.exe artisan list | findstr /I "requisition ledger"
C:\php\php.exe artisan ledger:status
```

Expect `ledger:refresh`, `ledger:status`, `requisition:refresh`, and an exit of 0 with the
"not configured" note.

---

## Step 2 — [DB] Preflight

### 2a. The source and the Phase 1 dependency

Run in SSMS against `FinanceAutomationSystem`. Read every row.

```sql
USE FinanceAutomationSystem;

SELECT 'ledger snapshot rows'   AS check_, CONVERT(varchar(20), COUNT(*)) AS value FROM dbo.FinanceLedgerSnapshot
UNION ALL SELECT 'access view exists',    CASE WHEN OBJECT_ID('dbo.vw_WebAppUserAccess','V') IS NULL THEN 'MISSING - STOP' ELSE 'ok' END
UNION ALL SELECT 'encumbrance in scope',  CONVERT(varchar(20), (SELECT COUNT(*) FROM dbo.[0040DBudgetsEncumbrance] WHERE [Status] IN ('AP','PO','RT','HD','PN')))
UNION ALL SELECT 'bad shipment rows',     CONVERT(varchar(20), (SELECT COUNT(*) FROM dbo.[0098FPOShipmentDetails] WHERE TRY_CONVERT(int, POLineID) IS NULL OR TRY_CONVERT(decimal(19,4), QTYShipped) IS NULL))
UNION ALL SELECT 'phase 2 already there', CONVERT(varchar(20), (SELECT COUNT(*) FROM sys.objects WHERE name LIKE 'FinanceRequisition%' OR name LIKE 'vw_FinanceRequisition%' OR name = 'usp_RefreshFinanceRequisition'));

-- Ledger freshness per year. Every year should be OK.
SELECT FinancialYear, RefreshedAt, RowsLoaded, Outcome,
       DATEDIFF(hour, RefreshedAt, SYSDATETIME()) AS hours_old
FROM dbo.FinanceLedgerRefresh ORDER BY FinancialYear DESC;
```

| Check | Expected | If not |
|---|---|---|
| ledger snapshot rows | > 20,000 | **STOP** — Phase 1 is not built |
| access view exists | `ok` | **STOP** — Phase 1 is not deployed |
| encumbrance in scope | ~106,000 | a very different number is worth understanding first |
| **bad shipment rows** | **0** | **STOP** — Step 4 will abort on gate A2. Fix the source rows |
| phase 2 already there | `0` | someone has been here before; re-read this runbook |
| every year `Outcome` | `OK` | resolve the aborted year before continuing |

> **On `hours_old`.** The reconciliation gate only *enforces* on fiscal years the ledger refreshed
> within 36 hours; older years are compared and merely recorded. Years showing more than 36 hours
> will not block the build. That is deliberate — see `financesqlupdatep2.md`.

### 2b. Read the Agent job BEFORE changing it

**This has never been done on production.** Dev matching the committed script is corroboration,
not proof. Run as an admin login:

```sql
SELECT s.step_id, s.step_name, s.on_success_action, s.on_fail_action,
       s.retry_attempts, s.retry_interval, s.database_name
FROM msdb.dbo.sysjobs AS j
JOIN msdb.dbo.sysjobsteps AS s ON s.job_id = j.job_id
WHERE j.name = N'SWRHA Finance - Ledger Refresh'
ORDER BY s.step_id;
```

**Expect exactly ONE row:**

| step_id | step_name | on_success_action | on_fail_action | retry_attempts | retry_interval | database_name |
|---|---|---|---|---|---|---|
| 1 | `Refresh snapshot` | **1** | 2 | 2 | 20 | `FinanceAutomationSystem` |

* **More than one step** → someone has already amended the job. **STOP.** Step 7 assumes step 1 is
  the only step and appends after it. Re-read this runbook against what is actually deployed.
* **Different settings** → Step 7b copies step 1's settings deliberately. Match what you find,
  not what is written here.

Also confirm Agent is running and note the service account:

```sql
SELECT servicename, status_desc, service_account FROM sys.dm_server_services;
```

---

## Step 3 — [DB] Install the objects

```
sql\FinanceRequisition.sql
```

Open it in SSMS against `FinanceAutomationSystem` and execute. It is idempotent — safe to re-run.

The script ends with five verification queries that return nothing meaningful yet (the snapshot is
empty until Step 4). That is expected. **What matters is that no error was raised.**

Confirm all six objects exist:

```sql
SELECT name, type_desc FROM sys.objects
WHERE name IN ('FinanceRequisitionSnapshot','FinanceRequisitionSnapshot_Staging',
               'FinanceRequisitionRefresh','usp_RefreshFinanceRequisition',
               'vw_FinanceRequisitionDetail','vw_FinanceRequisitionDetailUnscoped')
ORDER BY name;
```

Six rows. Anything less, stop.

---

## Step 4 — [DB] Build it by hand, once

**Do this before scheduling it.** Scheduling a procedure that has never run once is how a failure
first becomes visible at 21:30 to nobody.

```sql
SET STATISTICS TIME OFF;
EXEC dbo.usp_RefreshFinanceRequisition;
```

> **This is the go/no-go point of the release**, and it is the first time the reconciliation gate
> has ever compared all fiscal years on production data. It either returns a result row, or it
> throws and nothing is written. There is no in-between and nothing to undo.

**A successful run returns one row.** Measured on a production restore, 2026-08-27 —
**re-measure, do not expect these exact numbers:**

| Column | Reference value | What it means |
|---|---|---|
| `RowsLoaded` | 106,410 | requisition lines across every fiscal year |
| `DurationSeconds` | 11–14 | if this is minutes, something is wrong — investigate before scheduling |
| `FiscalYearsLoaded` | 15 | FY2022 and FY2023 legitimately have no rows |
| `AccountsLoaded` | 1,644 | |
| `TotalApproved` / `TotalRouting` | 419,763,859.97 / 35,455,901.88 | goods-and-services scope, all years |
| `ReconAccountsCompared` | 22,325 | |
| **`ReconMismatches`** | **0** | **must be 0 — the build aborts otherwise** |
| `ReconStaleYearDrift` | 0 | non-zero is not a failure; see below |
| `DuplicateGrainRows` | 0 | non-zero is a Phase 3 concern, not a money one |
| `UnparsedSegmentRows` | 685 | rows whose account number has fewer than five delimiters |

**`ReconStaleYearDrift > 0` is not a failure.** It counts accounts that disagree on fiscal years
the *ledger* has not refreshed recently — a closed year that moved in the source, which the
summary will not pick up until the monthly full rebuild. Expect the next full ledger rebuild to
clear it. Investigate only if it does not.

**`UnparsedSegmentRows`** are invisible to every user, and the ledger hides the same accounts the
same way. Recorded, not gated. Not a blocker.

### If it THROWS

| Error | Meaning | Action |
|---|---|---|
| `51100` | a source column was renamed | Source schema changed. Stop; re-read the proc against it |
| `51101` | `vw_WebAppUserAccess` missing | Phase 1 not deployed |
| `51102` | non-numeric `POLineID` / `QTYShipped` | Fix the source rows. **Never** skip them — that would understate shipments and overstate commitments |
| `51103` | an open line hits a duplicated shipment key | Two different GP lines colliding. Needs finance/GP, and fixes **both** phases |
| **`51104` `RECONCILIATION FAILED`** | detail does not tie to the summary | **See below. Do not force it.** |

**On `RECONCILIATION FAILED`:** the message names the worst-drifting account. This is the gate
doing its job — the detail would have disagreed with the summary it drills into.

1. Nothing was written. The previous snapshot (if any) still stands.
2. Diagnose with `sql\Phase2ReconciliationTest.sql`.
3. Most likely cause is a **stale ledger**, not a Phase 2 defect. Refresh the ledger and retry:
   `EXEC dbo.usp_RefreshFinanceLedgerSnapshotAll @Force = 0;`
4. **`@Force = 1` does NOT bypass this gate, deliberately.** If you find yourself wanting to, the
   answer is upstream.

---

## Step 5 — [DB] Verify

Run all four. All four must be clean before you schedule anything.

```sql
-- 1. Shape by fiscal year. FY2022/FY2023 legitimately absent.
SELECT FinancialYear, COUNT(*) AS rows_,
       SUM(CASE WHEN [Status] IN ('AP','PO')      THEN 1 ELSE 0 END) AS approved_rows,
       SUM(CASE WHEN [Status] IN ('RT','HD','PN') THEN 1 ELSE 0 END) AS routing_rows,
       COUNT(DISTINCT AccountNumber) AS accounts
FROM dbo.FinanceRequisitionSnapshot GROUP BY FinancialYear ORDER BY FinancialYear DESC;

-- 2. FAN-OUT. MUST RETURN NOTHING. Any row means money is multiplying.
SELECT TOP 10 UserName, FinancialYear, RequisitionNumber, PONumber, LineNbr, COUNT(*) AS times_matched
FROM dbo.vw_FinanceRequisitionDetail
GROUP BY UserName, FinancialYear, RequisitionNumber, PONumber, LineNbr
HAVING COUNT(*) > 1;

-- 3. Detail vs summary, per user and fiscal year. EVERY diff must be 0.0000.
SELECT d.UserName, d.FinancialYear, COUNT(*) AS rows_,
       ROUND(SUM(CASE WHEN d.[Status] IN ('AP','PO')      THEN d.ExtendedCost ELSE 0 END) - l.sa, 4) AS diff_approved,
       ROUND(SUM(CASE WHEN d.[Status] IN ('RT','HD','PN') THEN d.ExtendedCost ELSE 0 END) - l.sr, 4) AS diff_routing
FROM dbo.vw_FinanceRequisitionDetail AS d
JOIN (SELECT UserName, FinancialYear, SUM(Approved) sa, SUM(Routing) sr
      FROM dbo.vw_FinanceLedger GROUP BY UserName, FinancialYear) AS l
  ON l.UserName = d.UserName AND l.FinancialYear = d.FinancialYear
GROUP BY d.UserName, d.FinancialYear, l.sa, l.sr
ORDER BY d.FinancialYear DESC;

-- 4. What the goods-and-services scope drops. Expect a small, explicable list.
SELECT DISTINCT AccountNumber, AccountDescription
FROM dbo.vw_FinanceRequisitionDetailUnscoped
WHERE IsGoodsAndServices = 0 AND FinancialYear = '2026';
```

| Query | Required result | If not |
|---|---|---|
| 1 | rows in every FY that has source data | investigate before scheduling |
| **2** | **no rows at all** | **STOP** — the access join is fanning out; roll back |
| **3** | **every diff `0.0000`** | **STOP** — detail disagrees with summary |
| 4 | 2 accounts on the 2026-08 data, both off reporting line 3 | a long list means the scope flag is wrong |

> **Sanity anchor.** On the 2026-08-27 production restore, FY2026 / `KCHARLES1` read
> **Approved TTD 41,936,916.59 and Routing TTD 4,512,250.19**, tying exactly to `vw_FinanceLedger`.
> Query 4 returned `4-80600-H01-401-0627-00-000` and `4-81500-H01-307-0601-00-000`.
> **These are dated measurements, not invariants.** Reconcile against *your* `vw_FinanceLedger`,
> which is what query 3 does — never against these numbers.

---

## Step 6 — [DB] Grants for the Agent account

Substitute the account from Step 2b (typically `NT SERVICE\SQLAgent$SQLEXPRESS`). The account
already holds `db_datareader`, which covers every table the build reads.

```sql
USE FinanceAutomationSystem;

GRANT EXECUTE        ON dbo.usp_RefreshFinanceRequisition      TO [NT SERVICE\SQLAgent$SQLEXPRESS];
GRANT INSERT, DELETE ON dbo.FinanceRequisitionSnapshot         TO [NT SERVICE\SQLAgent$SQLEXPRESS];
GRANT INSERT, DELETE ON dbo.FinanceRequisitionSnapshot_Staging TO [NT SERVICE\SQLAgent$SQLEXPRESS];
GRANT INSERT, DELETE ON dbo.FinanceRequisitionRefresh          TO [NT SERVICE\SQLAgent$SQLEXPRESS];
```

Note there is **no `ALTER`** grant: the proc uses `DELETE`, not `TRUNCATE`, precisely so this list
stays short. And **no `UPDATE`** on the log: it is append-only. `DELETE` on the log is only for the
200-run trim.

---

## Step 7 — [DB] Amend the Agent job

Two statements. **7a is the one that is easy to miss, and without it 7b is a step that never runs.**

### 7a. Step 1 must continue, not quit

```sql
EXEC msdb.dbo.sp_update_jobstep
    @job_name = N'SWRHA Finance - Ledger Refresh',
    @step_id  = 1,
    @on_success_action = 3;      -- was 1 (quit reporting success)
```

> Left at `1`, **step 2 would never run, and it would never run SILENTLY** — the job would report
> success every night while the requisition snapshot sat frozen at whenever you last built it by
> hand. Step 1's `@on_fail_action = 2` **stays**: if the ledger trips a gate, the job quits and
> both snapshots stay on their previous contents together.

### 7b. Add step 2

Settings match step 1 exactly. Adjust if Step 2b found different values.

```sql
EXEC msdb.dbo.sp_add_jobstep
    @job_name   = N'SWRHA Finance - Ledger Refresh',
    @step_name  = N'Refresh requisition detail',
    @subsystem  = N'TSQL',
    @database_name = N'FinanceAutomationSystem',
    @retry_attempts = 2,
    @retry_interval = 20,
    @on_success_action = 1,        -- quit reporting success (last step)
    @on_fail_action    = 2,        -- quit reporting failure
    @command = N'
SET NOCOUNT ON;
RAISERROR(''Finance requisition detail: full rebuild (all fiscal years).'', 0, 1) WITH NOWAIT;
EXEC dbo.usp_RefreshFinanceRequisition @Force = 0;
';
```

Verify:

```sql
SELECT s.step_id, s.step_name, s.on_success_action, s.on_fail_action
FROM msdb.dbo.sysjobs j JOIN msdb.dbo.sysjobsteps s ON s.job_id = j.job_id
WHERE j.name = N'SWRHA Finance - Ledger Refresh' ORDER BY s.step_id;
```

Expect:

| step_id | step_name | on_success_action | on_fail_action |
|---|---|---|---|
| 1 | Refresh snapshot | **3** | 2 |
| 2 | Refresh requisition detail | 1 | 2 |

**The schedule is untouched** — still daily 21:30, one job, one schedule.

---

## Step 8 — [DB] Run the whole job once, by hand

Do not wait for 21:30 to find out.

```sql
EXEC msdb.dbo.sp_start_job @job_name = N'SWRHA Finance - Ledger Refresh';
```

This runs the **ledger** refresh too, so allow for its normal duration. Then:

```sql
SELECT TOP 10 h.step_id, h.step_name, h.run_status, h.run_duration, LEFT(h.[message], 200) AS msg
FROM msdb.dbo.sysjobhistory AS h
JOIN msdb.dbo.sysjobs AS j ON j.job_id = h.job_id
WHERE j.name = N'SWRHA Finance - Ledger Refresh'
ORDER BY h.instance_id DESC;
```

**All three rows must show `run_status = 1`** — step 1, step 2, and the step_id 0 job outcome.
On the dev production-restore this read 24s + 23s = 48s total.

> **Do not judge "still running" from `sysjobactivity`.** Stale rows from previous Agent sessions
> leave `stop_execution_date` NULL and make a finished job look like it is still going. The
> history above is authoritative.

Then the drift check — **the assertion neither table can make on its own:**

```sql
SELECT
    (SELECT MAX(RefreshedAt) FROM dbo.FinanceLedgerRefresh      WHERE Outcome = 'OK') AS ledger_refreshed_at,
    (SELECT MAX(RefreshedAt) FROM dbo.FinanceRequisitionRefresh WHERE Outcome = 'OK') AS requisition_refreshed_at,
    ABS(DATEDIFF(minute,
        (SELECT MAX(RefreshedAt) FROM dbo.FinanceLedgerRefresh      WHERE Outcome = 'OK'),
        (SELECT MAX(RefreshedAt) FROM dbo.FinanceRequisitionRefresh WHERE Outcome = 'OK'))) AS drift_minutes;
```

`drift_minutes` should be small — under a minute on a nightly run, up to the ledger's full-rebuild
duration on the 1st. **Hours means step 2 did not run.**

---

## Step 9 — [WEB] Verify monitoring end to end

```powershell
C:\php\php.exe artisan ledger:status
```

Expect the requisition line to report real numbers with `outcome OK` and a small `drift`, and an
**exit code of 0**:

```powershell
C:\php\php.exe artisan ledger:status; echo "exit=$LASTEXITCODE"
```

A `NOTE:` line listing stale-year drift, duplicate grain or unparsed account numbers is
**informational, not a failure** — the command still exits 0.

**The health-check script needs no change** — it delegates to `ledger:status`, which now covers
both snapshots. But the task itself must exist. Check:

```powershell
Get-ScheduledTask | Where-Object { $_.TaskName -like "*Ledger*" } | Select TaskName, State
```

If that returns **nothing**, go to Step 9a. Without it, `ledger:status` is a command nobody runs
and the step-2 monitoring this phase adds does not actually monitor anything.

---

## Step 9a — [WEB] Register the health check task

Skip only if `Get-ScheduledTask` above already found it.

```powershell
cd C:\Apache24\htdocs\production\finance-automation-system\scripts
.\register-health-check-task.ps1 -WhatIf        # look first
.\register-health-check-task.ps1                # runs as SYSTEM
```

To run under a dedicated local account instead (preferred — see step 8 of
`instructionsforschedule.md` for creating `FinanceSvc` and its three grants):

```powershell
.\register-health-check-task.ps1 -RunAsUser "FinanceSvc"
```

The script refuses to register a task that would abort every run: it checks the app root, the
health script, PHP, and that `$appPath` inside `check-ledger-health.ps1` matches where you are
pointing it. It then runs `ledger:status` **once** before registering, and once more through the
task afterwards, printing the tail of `storage\logs\ledger-health-check.log`.

| Result | Meaning |
|---|---|
| `Last result : 0` | working |
| `267009` | still running — re-check in a moment |
| non-zero | read the log. **A stale snapshot is a correct non-zero result**, not a broken task |

---

## Step 9b — [DB] Database Mail

```
sql\FinanceDatabaseMail.sql
```

**Edit section 1 first** — SMTP server, port, from-address, recipient. Then work through the
sections in order; each verifies before moving on.

**Prefer the GUI?** `instructionsdatabasemail.md` is the full SSMS walkthrough — the Database Mail
Configuration Wizard, the Agent *Alert System* page, the operator, and the job's *Notifications*
page. It replaces sections 2, 3, 5 and 6. Same configuration either way.

Two GUI-specific traps it covers: the **Manage Profile Security** page must set the profile
public **and** default, or it never appears in Agent's mail-profile dropdown and nothing explains
why; and **SQL Agent must be restarted** after the Alert System page, or the setting is inert.

Whichever route you take, come back to the T-SQL for **section 4b** (real delivery verification),
the `sp_notify_operator` test in **section 6**, and **section 7**. The GUI has no equivalent of
any of the three.

Three things in that script are the ones people get wrong:

1. **"Mail queued." is not "mail sent."** `sp_send_dbmail` returns immediately regardless. Section
   4b reads `sysmail_allitems.sent_status` and `sysmail_event_log`, which is the real answer.
2. **Agent has its own mail setting.** Database Mail can work perfectly while the job still emails
   nobody. Section 5 sets it — and **SQL Agent must be restarted** before it takes effect.
3. **Section 7 is the only end-to-end proof.** It temporarily adds a step that always fails, runs
   the job, and removes it. Everything else can pass while the job still alerts no one.
   **Do not skip 7c** — a left-behind failing step means the job reports failure every night.

### What this does and does not buy you

| Failure | Database Mail | Health check task |
|---|---|---|
| A sanity gate aborts a step | ✅ | ✅ |
| Step 2 fails, step 1 succeeded | ✅ | ✅ (drift) |
| **SQL Agent service stopped** | ❌ | ✅ |
| **Job disabled** | ❌ | ✅ |
| **Job deleted** | ❌ | ✅ |

Database Mail alerts on a job that **runs and fails**. It cannot alert on one that **never runs** —
nothing fires to send the mail, and a disabled job never fails. That is why both exist, and why
Step 9a is not optional once you have Step 9b.

---

## Step 10 — Aftercare

1. **Watch the first unattended 21:30 run.** Next morning: `ledger:status` exits 0 and
   `drift_minutes` is small.
2. **Record the real production build time** in `financesqlupdateprogress.md`. The 11–14s figure
   is from a dev restore.
3. **Then tighten two thresholds**, both currently sized off pre-2026-08-25 ledger timings and
   almost certainly far looser than needed now that the whole job runs in about a minute:
   * `@ReconMaxLedgerAgeHours` (default 36) in `dbo.usp_RefreshFinanceRequisition`
   * `FINANCE_REQUISITION_MAX_DRIFT_MINUTES` (default 180) in the WEB `.env`
4. **Confirm the alerting actually alerts.** Section 7 of `sql/FinanceDatabaseMail.sql` for the
   job-failure path, and `Start-ScheduledTask` for the health-check path. Untested alerting is
   indistinguishable from no alerting until the day you need it.
5. **Phase 3 is unblocked.** Note for whoever builds it: version the filter caches against
   `dbo.FinanceRequisitionRefresh`, **not** `FinanceLedgerRefresh` — different job steps, and they
   can legitimately diverge.

---

## ⚠ Standing hazard — a database restore breaks step 2 silently

**Observed directly on 2026-08-27.** The Agent job lives in **`msdb`**; the Phase 2 objects live in
**`FinanceAutomationSystem`**. Restoring the user database therefore leaves step 2 in place calling
a stored procedure that no longer exists.

**After ANY restore of `FinanceAutomationSystem`:**

```
1. re-run sql\FinanceRequisition.sql
2. EXEC dbo.usp_RefreshFinanceRequisition;
3. php artisan ledger:status      (expect exit 0)
```

…before the next 21:30. The same applies to Phase 1's objects. The failure is loud rather than
silent — step 2 errors, the job reports failure, `ledger:status` reports drift — but it is better
fixed during the restore than discovered from an alert.

---

## Rollback

**Reverse order, and the order is load-bearing.** Dropping the procedure while the job step still
exists turns a healthy nightly job into one that fails every night at 21:30. The rollback script
refuses to run until the step is gone, but do it in this order anyway.

### R1 — [DB] Remove the job step

```sql
USE msdb;
EXEC msdb.dbo.sp_delete_jobstep
    @job_name = N'SWRHA Finance - Ledger Refresh', @step_id = 2;
EXEC msdb.dbo.sp_update_jobstep
    @job_name = N'SWRHA Finance - Ledger Refresh', @step_id = 1,
    @on_success_action = 1;      -- back to quit reporting success
```

Confirm the job is back to one step with `on_success_action = 1`.

### R2 — [DB] Drop the objects

Open `sql\FinanceRequisitionRollback.sql`, set the flags at the top, execute:

| Setting | Effect |
|---|---|
| `@DropObjects = 1`, `@DropData = 0` | **Recommended.** Drops the views, proc and staging; **keeps** the snapshot and the run log |
| `@DropObjects = 1`, `@DropData = 1` | Also drops the snapshot and the log |
| both `0` | No-op — the script says so and exits |

The script prints the last three runs before dropping anything, so the record survives in your
session output.

Keeping the data is the better default: the snapshot is rebuildable, but the log is the only
record of whether it ever reconciled. Re-running `sql\FinanceRequisition.sql` recreates every
object around retained data.

### R3 — [WEB] Optional

The app code degrades on its own and does not need reverting: `requisition:refresh` exits 1 with
"Could not find stored procedure", and `ledger:status` returns to reporting ledger freshness only.
Revert the checkout if you want the tree clean.

**Phase 1 is unaffected by all of the above.**

---

## Reference

| File | What it is |
|---|---|
| `financesqlupdatep2.md` | The plan, the reasoning, and the **As built** section that wins where they disagree |
| `financesqlupdateprogress.md` | Progress log for every phase |
| `sql/FinanceRequisition.sql` | The objects. Heavily commented — the *why* for each gate is in it |
| `sql/FinanceRequisitionAgentJobStep.sql` | The Step 7 statements, with §0 preflight and §8 rollback |
| `sql/FinanceRequisitionRollback.sql` | Guarded teardown |
| `sql/Phase2ReconciliationTest.sql` | Diagnose a `RECONCILIATION FAILED` |
| `sql/Phase2ScopeVariants.md` | Scoped vs unscoped, and the measurements behind the choice |
| `sql/FinanceDatabaseMail.sql` | Database Mail + Agent operator setup in T-SQL, with an end-to-end alert test |
| `instructionsdatabasemail.md` | The same configuration clicked through SSMS, step by step |
| `scripts/register-health-check-task.ps1` | Registers the health-check scheduled task on the WEB box |
| `instructionsforschedule.md` | The authority on the two-server topology and the `FinanceSvc` account |
| `oversight-prod-steps.md` | The Phase 1 runbook, for contrast |
