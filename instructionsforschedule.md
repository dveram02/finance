# SWRHA Finance — Windows Server Scheduler Setup

Follow these steps when you are ready to go live on the Windows Server.

The **CFS** and **SWRHA Nexus** applications are already running on the same server. All task
names and detection logic here are scoped to avoid any conflict with them.

Companion to `instructions.md` (the ledger rollout). Do this at **step 9** of that runbook.

---

## How Finance differs from Nexus — read this first

This setup deliberately mirrors `Inventory-app\scripts\instructions.md`, with **three
differences**. They are not oversights.

### 1. There is no queue worker, and no queue health check

Nexus registers **three** tasks: Scheduler, Queue Worker, Queue Health Check. Finance needs
**two**, and neither of them is a queue worker.

Finance dispatches nothing to the queue. There is no `app\Jobs`, no `app\Notifications`, no
`app\Mail`, and no `ShouldQueue` implementation anywhere in the codebase — it is a read-only
reporting portal that sends no notifications and queues no work. A queue worker would sit idle
forever.

> **Do not register a queue worker task for Finance.** Beyond being useless, it would add a
> third `artisan queue:work` process to the server, and **CFS's health check detects _any_
> `artisan queue:work` process** (see the conflict table at the end of Nexus's instructions).
> Adding one under Finance's path muddies CFS's monitoring for no benefit.

### 2. The Scheduler task needs a much longer time limit ⚠

Nexus's Scheduler task uses **"Stop task if it runs longer than: 5 minutes"**. **Do not copy
that value.**

`schedule:run` executes due commands **synchronously**. Finance's Sunday 03:00 job rebuilds
every fiscal year and runs for **20+ minutes**. A 5-minute limit would kill it mid-rebuild,
every single week.

A killed rebuild is *safe* — the snapshot swap is transactional, so the previous data survives —
but it never completes, so the ledger silently stops advancing. Use **4 hours**.

### 3. The health check watches snapshot staleness, not a process

Nexus's health check asks "is the queue worker alive?". Finance's asks "is the data still
fresh?", because that is where its silent failure lives:

> If the scheduler stops, **nothing errors**. No exception, no warning banner, no failed
> request. Every page keeps loading fast and looking correct. The figures simply stop moving,
> and the gap widens by a day every day.

There is no user-visible symptom until somebody notices a month-old total. That is why Task 2
below is not optional.

---

## Before You Start

1. Confirm the PHP executable path on the server:
   ```powershell
   where.exe php
   ```
   If it is not `C:\php\php.exe`, update `$phpPath` in `scripts\check-ledger-health.ps1`.

2. Confirm the application path on the server. These scripts assume:
   ```
   C:\Apache24\htdocs\production\finance
   ```
   If it differs, update `$APP_ROOT` / `$appPath` / `$ProjectRoot` in **every** script in
   `scripts\`, and the `cd /d` line in `manage-ledger.bat`.

3. Create the dedicated service account that runs the tasks.

   Both tasks run as a dedicated, low-privilege **local** account — `FinanceSvc` — NOT a
   server-admin account and NOT a domain account. Both databases authenticate via SQL logins in
   `.env`, so the Windows identity needs no DB rights; it only needs to run PHP and write to the
   app's log/cache folders. A separate account also keeps Finance isolated from the co-resident
   CFS and Nexus applications.

   ```powershell
   # Create the local standard (non-admin) account
   $pw = Read-Host -AsSecureString "Password for FinanceSvc"
   New-LocalUser -Name "FinanceSvc" -Password $pw -PasswordNeverExpires `
       -FullName "SWRHA Finance Service" -Description "Runs Finance scheduled tasks"

   # Grant Modify on the writable folders ONLY (code stays read+execute)
   $app = "C:\Apache24\htdocs\production\finance"
   icacls "$app\storage"         /grant "FinanceSvc:(OI)(CI)M" /T
   icacls "$app\bootstrap\cache" /grant "FinanceSvc:(OI)(CI)M" /T
   ```

   Then grant `FinanceSvc` the **"Log on as a batch job"** right:
   - Open **Local Security Policy** (`secpol.msc`) →
     *Local Policies → User Rights Assignment → Log on as a batch job*
   - Add `FinanceSvc`.

   Finally, confirm `FinanceSvc` can **read `.env`** (it holds the MySQL and SQL Server
   credentials) while that file is not broadly readable by other users.

4. Confirm `.env` on the server:
   ```dotenv
   APP_TIMEZONE=America/Port_of_Spain   # REQUIRED - without it "02:00" means 02:00 UTC = 22:00 local
   DB_HOST=<match how this server runs the app>
   FINANCE_LEDGER_REFRESH_TIMEOUT=1800  # see "Tune the timeout" below
   ```

5. Confirm the ledger SQL objects exist and the snapshot is built —
   `instructions.md` steps 2 and 4. **The scheduler has nothing to refresh until they are.**

---

## Step 1 — Verify Scripts

Before registering any tasks, test each manually from PowerShell:

```powershell
cd C:\Apache24\htdocs\production\finance

# Scheduler (should print nothing when no command is due)
php artisan schedule:run

# Confirm both entries are registered
php artisan schedule:list
#   0 2 * * *  php artisan ledger:refresh
#   0 3 * * 0  php artisan ledger:refresh --all

# Snapshot freshness (exits non-zero if stale — that is the health check)
php artisan ledger:status

# A single-year refresh, to prove the SQL Server plumbing end to end (~90-110s)
php artisan ledger:refresh --year=2026
```

> There is **no `--dry-run`** on `ledger:refresh`, unlike the Nexus commands. It does not need
> one: the refresh builds into a staging table and only swaps into the live snapshot after its
> sanity gates pass, so a bad run leaves the previous data in place. `ledger:status` is the
> read-only inspection command.

---

## Step 2 — Register Windows Task Scheduler Tasks

Open **Task Scheduler** (`taskschd.msc`) and create the following **2** tasks.
Use "Create Task" (not "Create Basic Task") for full control.

---

### Task 1: SWRHA Finance - Scheduler

Runs `php artisan schedule:run` every minute. Laravel then fires the right commands at their
configured times (02:00 daily, 03:00 Sundays).

| Setting | Value |
|---|---|
| Name | `SWRHA Finance - Scheduler` |
| Description | Fires Laravel scheduled commands (nightly + weekly finance ledger snapshot refresh) |
| Run As | `FinanceSvc` (dedicated local service account — see Before You Start) |
| Run whether logged on or not | Yes (requires "Log on as a batch job" right) |
| Run with highest privileges | No (unchecked — least privilege) |

**Triggers tab:**
- New trigger → Daily
- Start: today's date at 00:00
- Repeat task every: **1 minute**
- For a duration of: **1 day**
- Enabled: Yes

**Actions tab:**
- Action: Start a program
- Program: `powershell.exe`
- Arguments:
  ```
  -NonInteractive -ExecutionPolicy Bypass -File "C:\Apache24\htdocs\production\finance\scripts\run-scheduler.ps1"
  ```

**Settings tab:**
- Stop task if it runs longer than: **4 hours** ⚠ **NOT 5 minutes — see "How Finance differs" above**
- If the task is already running: **Do not start a new instance**

> The "Do not start a new instance" setting is what makes the long weekly rebuild safe: the
> per-minute triggers that fire during those 20+ minutes are simply skipped.

---

### Task 2: SWRHA Finance - Ledger Health Check

Runs every 30 minutes to verify the snapshot is fresh and the scheduler task is alive.

| Setting | Value |
|---|---|
| Name | `SWRHA Finance - Ledger Health Check` |
| Description | Monitors finance ledger snapshot freshness, scheduler task state, and disk space |
| Run As | `FinanceSvc` |
| Run whether logged on or not | Yes |
| Run with highest privileges | No (unchecked) |

**Triggers tab:**
- New trigger → Daily
- Start: today's date at 00:00
- Repeat task every: **30 minutes**
- For a duration of: **1 day**
- Enabled: Yes

**Actions tab:**
- Action: Start a program
- Program: `powershell.exe`
- Arguments:
  ```
  -NonInteractive -ExecutionPolicy Bypass -File "C:\Apache24\htdocs\production\finance\scripts\check-ledger-health.ps1"
  ```

**Settings tab:**
- Stop task if it runs longer than: 5 minutes
- If the task is already running: Do not start a new instance

> 30 minutes rather than Nexus's 5: the thing being watched changes once a day, not once a
> second. A stale snapshot is not more urgent for being noticed 25 minutes sooner.

---

## Step 3 — Verify Tasks Are Running

1. **Manually trigger the scheduler:**
   - Task Scheduler → `SWRHA Finance - Scheduler` → right-click → Run
   - Check `storage\logs\scheduler\schedule-YYYY-MM-DD.log`

2. **Manually trigger the health check:**
   - Right-click `SWRHA Finance - Ledger Health Check` → Run
   - Check `storage\logs\ledger-health-check.log`
   - Should show `OK: Scheduler task state=Ready...` and `OK: Ledger snapshot is fresh.`

3. **The only real proof** — wait for one scheduled 02:00 run and confirm `RefreshedAt`
   advanced without anyone touching it:
   ```powershell
   php artisan ledger:status
   ```

---

## Step 4 — Optional: Enable Email Alerts

Edit `scripts\check-ledger-health.ps1`:

```powershell
$alertEmail        = "your-email@swrha.com"
$enableEmailAlerts = $true

# Also update SMTP settings inside Send-Alert:
$smtpServer   = "your.smtp.server"
$smtpPort     = 587
$smtpUsername = "alerts@swrha.com"
$smtpPassword = "your-smtp-password"
```

Given that a stale ledger is invisible from the application, **this is worth enabling for
Finance even if you left it off for Nexus.**

---

## Tune the timeout after timing the full rebuild

`FINANCE_LEDGER_REFRESH_TIMEOUT` (seconds) is the expiry on the `withoutOverlapping()` lock.
The default **1800 (30 minutes)** was set against a reference server where `--all` took
**~20 minutes**.

**If `--all` runs longer than the timeout, the lock expires mid-run and a second invocation can
start on top of the first.** After `instructions.md` step 3 gives you a per-year figure, set
this to roughly **double** the measured full-loop duration — if one year takes 3 minutes, the
loop is ~40 minutes, so use `4800`. Erring high costs nothing; the lock releases normally on
completion.

Note this lock lives in the **default cache store (MySQL `cache_locks`)**, so **the refresh
cannot run while MySQL is down, even if SQL Server is perfectly healthy.** Unintuitive, but
by design.

---

## Manual Command Scripts (one-off runs)

The scheduler (Task 1) runs these automatically. Reach for the scripts only when an admin needs
to run something by hand. Each writes a timestamped log to `storage\logs\scheduler\`.

| Script | Command | Notes |
|---|---|---|
| `refresh-ledger.ps1` | `ledger:refresh` | `-Year 2026`, `-All`, `-Force`. ~90-110s **per fiscal year** |
| `check-ledger-health.ps1` | `ledger:status` | Also run by Task 2. `-MaxAgeHours` defaults to 36 |

```powershell
# Rebuild one year
powershell.exe -NonInteractive -ExecutionPolicy Bypass -File "C:\Apache24\htdocs\production\finance\scripts\refresh-ledger.ps1" -Year 2026

# Rebuild everything (20+ minutes)
powershell.exe -NonInteractive -ExecutionPolicy Bypass -File "C:\Apache24\htdocs\production\finance\scripts\refresh-ledger.ps1" -All

# Accept a genuine large movement that tripped a sanity gate
powershell.exe -NonInteractive -ExecutionPolicy Bypass -File "C:\Apache24\htdocs\production\finance\scripts\refresh-ledger.ps1" -Year 2026 -Force
```

`-Force` bypasses the **movement** gates only. It never bypasses the zero-row gate.

---

## Manual Ledger Management

Use `scripts\manage-ledger.bat` for day-to-day operations. Double-click it or run from a command
prompt — do NOT add it to Task Scheduler.

| Option | What it does |
|---|---|
| 1 | Check ledger freshness |
| 2 | Refresh current + prior fiscal year |
| 3 | Refresh a specific fiscal year |
| 4 | Refresh ALL fiscal years |
| 5 | Force refresh (bypass movement gates) |
| 6 | Scheduler task status |
| 7 | Run scheduler task now |
| 8 | View scheduler log |
| 9 | View health check log |
| 10 | Clear filter caches |

---

## Log File Locations

All logs are written to `storage\logs\` within the application folder.

| Log File | Written by |
|---|---|
| `scheduler\schedule-YYYY-MM-DD.log` | run-scheduler.ps1 (daily file) |
| `scheduler\refresh-ledger-YYYY-MM-DD.log` | refresh-ledger.ps1 (manual runs) |
| `ledger-health-check.log` | check-ledger-health.ps1 |
| `laravel.log` | Laravel application |

The authoritative refresh history is **not** in a log file — it is in SQL Server:

```sql
SELECT FinancialYear, RefreshedAt, RowsLoaded, DurationSeconds,
       TotalAllocation, TotalYTD, Outcome, Message
FROM dbo.FinanceLedgerRefresh
ORDER BY FinancialYear;
```

---

## Scheduled Command Times (for reference)

Controlled by `routes/console.php` — no changes needed here.

| Time | Command | Duration |
|---|---|---|
| 02:00 daily | `ledger:refresh` — rebuilds the current and prior fiscal year | ~2-4 min |
| 03:00 Sundays | `ledger:refresh --all` — rebuilds every fiscal year | **20+ min** |

Closed fiscal years never change, which is why the nightly run only touches two of them.

> ⚠ **02:00 is a placeholder.** It must move to just after the GL load that populates
> `0098AFinGLMaster` finishes — that window is still unknown and is tracked as a `TODO` in
> `routes/console.php`. Until then the snapshot may miss a day's postings. Check what CFS and
> Nexus run overnight at the same time (Nexus occupies 00:00, 01:00, 02:00 daily and 03:00
> Sundays — **both of Finance's slots currently collide with Nexus's**).

---

## Conflict Avoidance with CFS and Nexus

Three Laravel applications now run on this server. Laravel's scheduler is **per-application** —
Nexus's Scheduler task does not run Finance's commands and never will. Each app needs its own.

| Concern | CFS | SWRHA Nexus | SWRHA Finance |
|---|---|---|---|
| Task Scheduler names | `Laravel Queue Worker` | `SWRHA Nexus - *` | `SWRHA Finance - *` |
| Queue worker | Yes | Yes | **None — dispatches no jobs** |
| Service account | — | `NexusSvc` | `FinanceSvc` |
| App database | `cfs` | `inventory-app` | `finance` |
| Cache prefix | — | — | `finance_automation_system_cache_` (from `APP_NAME`) |
| Log files | `cfs\storage\logs\` | `nexus\storage\logs\` | `finance\storage\logs\` |

**Scheduling collisions are the real risk here**, not naming. Nexus already occupies 00:00,
01:00, 02:00 daily and 03:00 Sundays. Finance's 02:00 and Sunday 03:00 currently land on top of
Nexus's `gp:sync-reason-codes` and `model:prune`. Finance's weekly rebuild is by far the
heaviest job on the box — 20+ minutes of sustained SQL Server scanning. **Move Finance's times
when you resolve the GL-load window**, and check both other apps first:

```powershell
cd C:\Apache24\htdocs\production\nexus && php artisan schedule:list
cd C:\Apache24\htdocs\production\cfs   && php artisan schedule:list
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `RefreshedAt` never advances | Scheduler task not running, disabled, or failing | Check Task Scheduler history and `storage\logs\scheduler\` |
| Weekly rebuild never finishes | "Stop task if it runs longer than" set to 5 minutes | Set it to 4 hours (Task 1) |
| Runs at the wrong hour | `APP_TIMEZONE` missing from `.env` → UTC | Set `America/Port_of_Spain` |
| `schedule:list` throws a MySQL error | `withoutOverlapping()` locks live in MySQL `cache_locks` | Fix MySQL — the refresh cannot run without it, even if SQL Server is healthy |
| `Outcome = 'ABORTED'`, "Staging is empty" | Source returned nothing — usually the linked server | Check `GPSWRHA.SWRHA.CO.TT`. **Do not** `-Force`; the gate is protecting good data |
| `Outcome = 'ABORTED'`, "Total allocation/YTD moved…" | >25% movement — normal when a new FY opens or after a bulk reallocation | Confirm genuine, then `-Force` |
| Task returns `0x1` immediately | PHP not on `FinanceSvc`'s PATH | Use the full path to `php.exe` in the script, or fix the account's PATH |
| Task returns `0x2` | Wrong script path in the task action | Re-check the `-File` argument |
| Health check can't query the task | `FinanceSvc` lacks rights to read Task Scheduler | Harmless — it logs a warning and still checks freshness |
| Pages show stale dropdowns | Filter caches on the `file` store | `php artisan cache:clear file` (plain `cache:clear` does **not** touch them) |

---

## Acceptance Checklist

- [ ] `FinanceSvc` created, granted Modify on `storage\` + `bootstrap\cache\`, and "Log on as a batch job"
- [ ] `FinanceSvc` can read `.env`
- [ ] `APP_TIMEZONE=America/Port_of_Spain` set on production
- [ ] `php artisan schedule:list` shows both entries
- [ ] `php artisan ledger:refresh --year=<current FY>` completes by hand
- [ ] Task 1 registered, **time limit 4 hours** (not 5 minutes), "Do not start a new instance"
- [ ] Task 2 registered at 30-minute repeat
- [ ] **No** queue worker task registered for Finance
- [ ] Both tasks run successfully when triggered manually
- [ ] `FINANCE_LEDGER_REFRESH_TIMEOUT` set to ~double the measured `--all` duration
- [ ] Email alerts enabled on `check-ledger-health.ps1`
- [ ] Waited for one scheduled 02:00 run and confirmed `RefreshedAt` advanced on its own
- [ ] Schedule times checked against Nexus and CFS for collisions — **currently they collide**
- [ ] Nightly time moved to just after the GL load — **still outstanding**, window unknown
