# SWRHA Finance — Production Scheduling Setup

How to put the finance ledger refresh into production.

## The topology — read this first

**Production is two Windows servers.** Everything below depends on knowing which is which:

| Box | Runs | Owns |
|---|---|---|
| **Web server** | Apache 24, PHP (`C:\php\php.exe`), the Laravel app, MySQL (sessions/cache/queue) | The health-check task, `FinanceSvc`, `storage\logs\` |
| **DB server** | SQL Server 2022 (`sqlapp\SQLEXPRESS`), SQL Server Agent | The refresh job, all ledger objects, the `GPSWRHA` linked server |

A third machine, **`GPSWRHA.SWRHA.CO.TT`**, holds the Great Plains data the refresh reads across
the linked server. The web server never touches it.

The app reaches SQL over TCP as the `finance` SQL login (`SQLSRV_HOST` in `.env`) — there is no
Windows authentication anywhere in this design, which is why a local service account on the web
server needs no database rights at all.

**Two things get scheduled, in two different schedulers, on two different boxes:**

| What | Where | Which box | When |
|---|---|---|---|
| The ledger refresh | SQL Server Agent job `SWRHA Finance - Ledger Refresh` | DB server | Daily 21:30 |
| The staleness health check | Windows Task Scheduler `SWRHA Finance - Ledger Health Check` | Web server | Every 30 min |

There is **no** `schedule:run` task and **no** queue worker for Finance.

The refresh has **no dependency on the web server whatsoever** — Apache can be stopped, the app
deleted, the whole box rebuilt, and the snapshot still refreshes on time. The monitoring, however,
still depends on the web server *and* on the network path between the two boxes. That asymmetry is
the single most important consequence of the split; see
[What the two-server split changes](#what-the-two-server-split-changes) in Part 4.

**How to use this document:** work through Part 1 in order, steps 1 to 12. Do not skip ahead —
steps 1b, 3 and 5 are gates that are meant to fail before you build anything. Part 2 is alerting
and hardening (**A is not optional** — see why below), Part 3 is follow-up work, Part 4 is
background you only need when something goes wrong.

Each step is headed with the box it runs on. Steps 1, 1b and 8 to 12 are the **web** server;
steps 2 to 7 are the **DB** server.

Companion to `instructions.md` (the ledger rollout). Do this at **step 9** of that runbook.

---

# Part 1 — Setup, in order

## Step 1 — Confirm the basics (web server)

On the **web** server:

```powershell
where.exe php
```

**Expect:** `C:\php\php.exe`. If it is somewhere else, update `$phpPath` in
`scripts\check-ledger-health.ps1`.

Confirm the application path is `C:\Apache24\htdocs\production\finance`. If it differs, update
`$ProjectRoot` / `$appPath` in every script in `scripts\`, and the `cd /d` line in
`manage-ledger.bat`.

Confirm `.env` has:

```dotenv
APP_TIMEZONE=America/Port_of_Spain
DB_HOST=localhost              # MySQL is LOCAL to the web server. Never the literal `mysql`
SQLSRV_HOST=<the DB server>    # NOT localhost — SQL Server is on the other box
SQLSRV_PORT=1433
```

> ⚠ **`SQLSRV_HOST` must never be `localhost` or `.\SQLEXPRESS`.** If a SQL Server instance also
> happens to be installed on the web server, a `localhost` host silently connects to *that* empty
> instance: no error, no data, and hours spent looking at the wrong machine. `DB_HOST` (MySQL) is
> local; `SQLSRV_HOST` is remote. They are not the same box and never will be.

Confirm the ledger SQL objects exist and the snapshot has been built at least once —
`instructions.md` steps 2 and 4. **The job has nothing to refresh until they are.**

```powershell
php artisan ledger:status
```

That command is itself the end-to-end proof: it opens a `sqlsrv` connection from the web server to
the DB server and reads `dbo.FinanceLedgerRefresh`. If it errors, do step 1b before anything else.

---

## Step 1b — ⚠ GATE: the link between the two boxes

Only needed the first time, or after either box is rebuilt or moved. **Skip nothing here** — every
item is something that works by default when the app and SQL share a box and does not when they
don't.

**On the web server:**

| Check | Why it matters now |
|---|---|
| `php -m` lists `sqlsrv` and `pdo_sqlsrv` | The extension lives on the *web* box. SQL Server being installed on the other box gives it nothing |
| Microsoft ODBC Driver for SQL Server (17 or 18) installed | Required by the extension. **Match the version deliberately** — `prodfix-steps.md` records `sqlcmd` broken by an ODBC 17 build against a Driver 18 install. Driver 18 defaults to `Encrypt=yes`, which is why `.env` sets `SQLSRV_ENCRYPT=yes` and `SQLSRV_TRUST_SERVER_CERT=true` |
| `Test-NetConnection <db-server> -Port 1433` succeeds | Proves route + firewall before you blame the app |

**On the DB server:**

| Check | Why |
|---|---|
| TCP/IP enabled in SQL Server Configuration Manager | Frequently off on a named instance. Local connections use shared memory and never reveal it |
| The instance listens on a **static** port | `.env` passes `SQLSRV_HOST=<host>\SQLEXPRESS` with `SQLSRV_PORT=1433`. A named instance on a *dynamic* port ignores that and fails unless SQL Browser is reachable on **UDP 1434** |
| Inbound firewall: **TCP 1433** (plus **UDP 1434** if resolving by instance name) | |
| **Mixed-mode authentication is enabled** | The whole design authenticates as the `finance` SQL login. Windows-only auth cannot work across boxes here |

**On both — the clocks:**

```powershell
Get-Date; (Get-Timezone).Id; w32tm /query /status
```

**Both servers must be on the same timezone (`America/Port_of_Spain`, UTC-4, no DST) and
NTP-synced.** This is not cosmetic:

- `RefreshedAt` is written with `SYSDATETIME()` — the **DB server's** clock
  (`sql/FinanceLedger.sql`).
- `ledger:status` parses that naive timestamp in `APP_TIMEZONE` and compares it to `now()` — the
  **web server's** clock (`app/Console/Commands/LedgerStatus.php`).

On one box those were always the same clock. On two they are not. A DB server left on UTC makes
every refresh read 4 hours *younger* than it is, so the 36-hour staleness window silently becomes
40. Skewed the other way you get a CRITICAL alert every night against a perfectly healthy
snapshot. The job's own day-of-month branching and Laravel's `currentFiscalYear()` read the same
two clocks, so they can also disagree across the 1 October boundary.

---

## Step 2 — Get the SQL Agent service account name (DB server)

> **Steps 2 to 7 all execute on the DB server.** You can run them through SSMS from anywhere, but
> confirm what you are connected to before creating anything:
>
> ```sql
> SELECT @@SERVERNAME, SERVERPROPERTY('MachineName'), SERVERPROPERTY('Edition'),
>        SERVERPROPERTY('EngineEdition');
> ```
>
> `MachineName` must be the **DB** server. Creating the Agent job on the wrong instance produces a
> job that runs, succeeds, and refreshes a database nobody reads.
>
> These steps are **per-instance**. Nothing about them carries across a server move — if the SQL
> instance is ever rebuilt or relocated, re-run 2 through 7 and re-tick the checklist, gates
> included.

Open SSMS, connect to `sqlapp\SQLEXPRESS` **as a sysadmin login**. The application's `finance`
login cannot do any of Part 1 and should not be able to.

Run **section 1** of `sql\FinanceLedgerAgentJob.sql`:

```sql
SELECT servicename, service_account, status_desc, startup_type_desc
FROM sys.dm_server_services
WHERE servicename LIKE 'SQL Server Agent%';
```

**Expect:** `Running` / `Automatic`. **Write down the `service_account` value** — typically
`NT SERVICE\SQLAgent$SQLEXPRESS`. Steps 4 and 5 both need it.

If the "SQL Server Agent" node is missing from Object Explorer, you are not sysadmin or the
service is stopped. Fix that before continuing.

---

## Step 3 — ⚠ GATE: check the linked server mapping

The refresh reads `[GPSWRHA.SWRHA.CO.TT].[SWRHA].[dbo].[GL40200]` — a **third** machine, reached
from the DB server, never from the web server. If the Agent runs under a virtual account
(`NT SERVICE\SQLAgent$SQLEXPRESS`), that account is local to the DB server and presents itself over
the network as the DB server's *machine* account, which is why a mapping that works for the
`finance` login proves nothing about the job. Run **section 2**:

```sql
SELECT s.name AS linked_server, l.local_principal_id,
       l.uses_self_credential, l.remote_name
FROM sys.servers s
LEFT JOIN sys.linked_logins l ON l.server_id = s.server_id
WHERE s.is_linked = 1;
```

| Result | Meaning | Action |
|---|---|---|
| `local_principal_id = 0`, `uses_self_credential = 0`, `remote_name` set | Fixed mapping, works for every login | Continue to step 4 |
| `uses_self_credential = 1` | Pass-through — works for `finance`, will **fail** for the Agent account | Add a mapping for the Agent account first |

GUI equivalent: Server Objects → Linked Servers → `GPSWRHA.SWRHA.CO.TT` → Properties →
**Security**. *"Be made using the login's current security context"* is the setting that breaks it.

---

## Step 4 — Create the Agent login and grants

Run **section 3** of `sql\FinanceLedgerAgentJob.sql`, uncommented, with the account name from
step 2 substituted throughout:

```sql
USE FinanceAutomationSystem;

CREATE LOGIN [NT SERVICE\SQLAgent$SQLEXPRESS] FROM WINDOWS;   -- skip if it exists
CREATE USER  [NT SERVICE\SQLAgent$SQLEXPRESS] FOR LOGIN [NT SERVICE\SQLAgent$SQLEXPRESS];

GRANT EXECUTE ON dbo.usp_RefreshFinanceLedgerSnapshot    TO [NT SERVICE\SQLAgent$SQLEXPRESS];
GRANT EXECUTE ON dbo.usp_RefreshFinanceLedgerSnapshotAll TO [NT SERVICE\SQLAgent$SQLEXPRESS];
ALTER ROLE db_datareader ADD MEMBER [NT SERVICE\SQLAgent$SQLEXPRESS];
GRANT INSERT, DELETE ON dbo.FinanceLedgerSnapshot         TO [NT SERVICE\SQLAgent$SQLEXPRESS];
GRANT INSERT, DELETE ON dbo.FinanceLedgerSnapshot_Staging TO [NT SERVICE\SQLAgent$SQLEXPRESS];
GRANT INSERT, UPDATE ON dbo.FinanceLedgerRefresh          TO [NT SERVICE\SQLAgent$SQLEXPRESS];
```

---

## Step 5 — ⚠ GATE: prove the Agent account can read GP

**This is the most likely failure of the whole setup.** Run **section 4**:

```sql
EXECUTE AS LOGIN = 'NT SERVICE\SQLAgent$SQLEXPRESS';
SELECT TOP 1 SGMTNUMB, SGMNTID, DSCRIPTN
    FROM [GPSWRHA.SWRHA.CO.TT].[SWRHA].[dbo].[GL40200];
SELECT TOP 1 * FROM [GPSWRHA.SWRHA.CO.TT].[SWRHA].[dbo].[DBA_Clusters];
REVERT;
```

Those are the two tables `fn_FinanceLedgerSource` actually reads across the linked server.

| Result | Meaning |
|---|---|
| One row from each | **Pass.** Continue to step 6 |
| Msg 7416 / 18456 / 15404, "Access to the remote server is denied", or an SSPI/delegation error | **Fail.** Back to step 3 — the Agent account needs its own linked-server mapping |
| Msg 207 "Invalid column name" | The **connection worked**; only the column list is wrong. Binding a four-part name requires fetching remote metadata, so reaching this error means authentication succeeded |

Do not skip this and create the job anyway — a linked-server permission failure surfaces in the
job history looking like a *data* error, hours later.

---

## Step 6 — Create the Agent job

Run **section 5** of `sql\FinanceLedgerAgentJob.sql` (5a through 5d). It is idempotent — it drops
any previous version first, so it is safe to re-run.

This creates one job, with one step that branches on day-of-month, on one daily schedule:

| Day | What runs | Duration |
|---|---|---|
| The 1st | Every fiscal year | 16-38 min |
| Every other day | Current + prior fiscal year | 2-6 min |

**Prefer the GUI?** Appendix C of the SQL file is a full New Job dialog walkthrough.
⚠ If you use it, paste the **GUI STEP COMMAND** block from Appendix C — *not* the `@command`
text from section 5c, whose quotes are escaped for use inside a string literal.

---

## Step 7 — Run the job once and verify

```sql
EXEC msdb.dbo.sp_start_job @job_name = N'SWRHA Finance - Ledger Refresh';
```

GUI: right-click the job → **Start Job at Step…**. Watch it in **Job Activity Monitor**.

Unless today is the 1st, expect 2-6 minutes. Then check both records — Agent's view
(**section 6b**) and the authoritative one (**section 6c**):

```sql
SELECT FinancialYear, RefreshedAt, RowsLoaded, DurationSeconds,
       TotalAllocation, TotalYTD, Outcome, Message
FROM FinanceAutomationSystem.dbo.FinanceLedgerRefresh
ORDER BY FinancialYear;
```

**Expect:** `Outcome = 'OK'` and a `RefreshedAt` from the last few minutes.

**If `Outcome = 'ABORTED'`,** a sanity gate held the previous snapshot on purpose. Read the
`Message` before forcing anything — see Troubleshooting in Part 4.

---

## Step 8 — Create the `FinanceSvc` account (web server)

Back on the **web** server. This is for the health check task only: a low-privilege **local**
account — not a server-admin account, not a domain account.

`FinanceSvc` needs **no rights on the DB server, and no account there**. The health check shells
out to `php artisan ledger:status`, which connects as the `finance` SQL login from `.env`. The
Windows identity never crosses the network. That is the whole reason a purely local account still
works with the database on another box — and the reason the SQL instance must accept SQL
authentication (step 1b).

```powershell
$pw = Read-Host -AsSecureString "Password for FinanceSvc"
New-LocalUser -Name "FinanceSvc" -Password $pw -PasswordNeverExpires `
    -FullName "SWRHA Finance Service" -Description "Runs the Finance ledger health check"

$app = "C:\Apache24\htdocs\production\finance"
icacls "$app\storage"         /grant "FinanceSvc:(OI)(CI)M" /T
icacls "$app\bootstrap\cache" /grant "FinanceSvc:(OI)(CI)M" /T
```

Then grant it **"Log on as a batch job"**: `secpol.msc` → *Local Policies → User Rights
Assignment → Log on as a batch job* → add `FinanceSvc`.

Finally confirm `FinanceSvc` can **read `.env`** while that file is not broadly readable.

---

## Step 9 — Register the health check task

Task Scheduler (`taskschd.msc`) → **Create Task** (not "Create Basic Task").

| Setting | Value |
|---|---|
| Name | `SWRHA Finance - Ledger Health Check` |
| Description | Monitors finance ledger snapshot freshness, Apache, and disk space |
| Run As | `FinanceSvc` |
| Run whether logged on or not | Yes |
| Run with highest privileges | No (unchecked) |

**Triggers:** Daily, start today at 00:00, **repeat every 30 minutes** for a duration of 1 day.

**Actions:** Start a program → `powershell.exe`, arguments:

```
-NonInteractive -ExecutionPolicy Bypass -File "C:\Apache24\htdocs\production\finance\scripts\check-ledger-health.ps1"
```

**Settings:** Stop task if it runs longer than 5 minutes. If already running, do not start a new
instance.

---

## Step 10 — Verify the health check

Right-click the task → **Run**. Then open `storage\logs\ledger-health-check.log`.

**Expect:** `OK: Ledger snapshot is fresh.`

> ⚠ **Know what a failure here does and does not mean.** `ledger:status` exits non-zero for a
> *stale snapshot* and for a *connection error* alike, and the alert body says "the scheduler is
> probably not running" either way. With the database on another box, "the web server cannot reach
> the DB server" is now a routine cause — firewall change, link down, expired certificate, SQL
> restart — and it points the reader at the wrong machine. Before touching the Agent job, read the
> logged output: `Could not read dbo.FinanceLedgerRefresh: …` is a **connectivity** failure, and
> the refresh is probably running perfectly well without you.

---

## Step 11 — Confirm it runs unattended

Wait for one scheduled 21:30 run, then:

```powershell
php artisan ledger:status
```

**Expect:** `RefreshedAt` advanced without anyone touching it. **This is the only real proof** —
everything before it only shows the pieces work when a human pushes them.

---

## Step 12 — Clean up

On the **web** server:

- Delete `storage\logs\scheduler\`. It is dead: `run-scheduler.ps1` was removed and
  `refresh-ledger.ps1` now writes to `storage\logs\ledger\`.
- Confirm no `schedule:run` task and no queue worker task exist for Finance.
- Confirm `php artisan schedule:list` reports **no scheduled tasks**.
- Confirm `SWRHA Finance - Ledger Health Check` is the **only** Finance task registered.
- **Retire `refresh-ledger.ps1` and `manage-ledger.bat` options 2-5** once the initial build is
  done. They wrap the same proc the Agent job calls, nothing schedules them, and they run it the
  slow way now that the database is on another box. Manual refreshes belong in SSMS.

---

## Part 1 acceptance checklist

- [ ] 1. PHP path, app path and `.env` confirmed (`SQLSRV_HOST` is the **remote** box); `ledger:status` runs
- [ ] 1b. `sqlsrv` + ODBC driver present; TCP 1433 reachable; static port; mixed-mode auth; **both clocks agree**
- [ ] 2. Connected instance confirmed as the DB server; Agent service Running/Automatic; service account name recorded
- [x] 3. Linked server mapping checked
- [ ] 4. Agent login created and granted
- [x] 5. **`EXECUTE AS` test returned a row from `GL40200`**
- [x] 6. Job `SWRHA Finance - Ledger Refresh` exists and is enabled
- [x] 7. Job started manually; `FinanceLedgerRefresh` shows `Outcome = 'OK'`
- [ ] 8. `FinanceSvc` created, ACLs granted, batch-logon right granted, can read `.env`
- [ ] 9. Health check task registered at 30-minute repeat
- [ ] 10. Health check ran and logged `OK: Ledger snapshot is fresh.`
- [ ] 11. One scheduled 21:30 run completed on its own
- [ ] 12. `storage\logs\scheduler\` deleted; `schedule:list` empty; no queue worker; health check is the only Finance task
- [ ] A2. Database Mail + Agent operator configured — the only alert that survives the web server or the link being down

---

# Part 2 — Alerting and hardening

The schedule works without any of this. Do it after Part 1 is green — but do **A**.

## A — Alerting (do both; A2 is no longer really optional)

A stale ledger is **invisible from the application** — every page loads fast and looks correct.

**A1. Health check email** — covers staleness whatever the cause, and is the only thing watching
the web server. Edit `scripts\check-ledger-health.ps1`:

```powershell
$alertEmail        = "your-email@swrha.com"
$enableEmailAlerts = $true
# also set $smtpServer / $smtpPort / $smtpUsername / $smtpPassword inside Send-Alert
```

**A2. Database Mail + Agent operator** — job-failure email from SQL Server itself. Setup is in
`sql\FinanceLedgerAgentJob.sql`, **Appendix B**.

**Why A2 stopped being optional when the database moved to its own box:** A1 originates on the web
server and reaches the database over the network, so it is blind in exactly two situations — the
web server being down, and the *link* being down — and the second is a routine event that has
nothing to do with the data. A2 originates on the DB server and needs neither. It is also the only
alert that can reach you about the DB server's own resources: the health check's disk and log
checks measure the **web** server's drive, while the disk that can actually kill a refresh
(snapshot + `_Staging` + tempdb against the 6.38M-row scan) is on a machine that task cannot see.

Neither replaces the other, and neither replaces the health check: **a disabled job never fails,
so it never sends mail.**

## Optional B — Revoke `EXECUTE` from the `finance` login

The app connects as `finance`, a read-only login. Under the old Laravel schedule it needed
`EXECUTE` on a proc that truncates and rewrites the snapshot. Agent removes that need:

```sql
REVOKE EXECUTE ON dbo.usp_RefreshFinanceLedgerSnapshot    FROM [finance];
REVOKE EXECUTE ON dbo.usp_RefreshFinanceLedgerSnapshotAll FROM [finance];
```

**Cost:** `php artisan ledger:refresh`, `refresh-ledger.ps1` and `manage-ledger.bat` options 2-5
stop working by design. Manual refreshes move to SSMS. `ledger:status` is read-only and
unaffected. Do this only after the job has run unattended for a few days.

The two-server split argues *for* doing this. Driving the refresh from the web server now means
holding one connection open across the network for 243 seconds per fiscal year (40-55 minutes for
`--all`, per the production timings in `prodfix-steps.md`), exposed to firewall idle timeouts that
a local connection never met. Running it on the DB server, where the work actually happens, is
both faster and fewer moving parts.

Also in `sql\FinanceLedgerAgentJob.sql`, **Appendix D**.

## Optional C — Surface the job's own state in the health check

The health check asserts staleness against the clock; it does not read the job. To have it report
the job's state as well, grant the role and add the probe to `App\Console\Commands\LedgerStatus`
so it stays behind artisan rather than putting a second set of credentials in a script:

```sql
USE msdb;
CREATE USER [finance] FOR LOGIN [finance];
ALTER ROLE SQLAgentReaderRole ADD MEMBER [finance];
```

## Optional D — `sp_getapplock` hardening

Agent already refuses to start a job that is already running. This only protects against a manual
SSMS run landing on top of a scheduled one. See `sql\FinanceLedgerAgentJob.sql`, **Appendix A** —
deliberately left unapplied, since it edits a working production proc for a risk the schedule no
longer has.

---

# Part 3 — Follow-ups

Not optional, but not blocking go-live either.

## F1. Confirm the GL load window ⚠ do this in the first week

**The 21:30 schedule rests on one assumption: that the external process writing
`dbo.0098AFinGLMaster` runs during the business day, not overnight.**

That process is not an Agent job on this instance — a search of `sysjobsteps` for `0098A` /
`GPSWRHA` / `GL` returns nothing — and the table is *local* to `FinanceAutomationSystem` (only
`GL40200` and `DBA_Clusters` come across the linked server). So something external writes it and
its window is unconfirmed.

- **Load runs during the day** → 21:30 sits after it. Correct, and better than any overnight slot.
- **Load runs overnight** → 21:30 reads before it lands and the snapshot sits a **full day
  behind, permanently and silently** — the health check would see `RefreshedAt` advancing normally
  every night.

`sql\FinanceLedgerAgentJob.sql` **section 7** has the queries.
`sys.dm_db_index_usage_stats.last_user_insert` sampled over a few days is enough to settle it.

## F2. Check the backup duration

`Daily Backups.Subplan_1` runs 01:15 Tue-Sat. 21:30 is hours clear of it, so this is confirmation
rather than a risk — but worth having on record before anyone proposes moving the refresh:

```sql
SELECT TOP 20 j.name, msdb.dbo.agent_datetime(h.run_date, h.run_time) AS started, h.run_duration
FROM msdb.dbo.sysjobhistory h JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id
WHERE j.name LIKE 'Daily Backups%' AND h.step_id = 0
ORDER BY h.run_date DESC, h.run_time DESC;
```

---

# Part 4 — Reference

## Why the refresh is a SQL Agent job

An earlier design ran this through Laravel's scheduler on a per-minute Windows task, justified by
*"production's SQL Server edition is unconfirmed and Express has no Agent."* **That premise was
false.** The instance is *named* `sqlapp\SQLEXPRESS`, but:

```
Edition       : Standard Edition (64-bit)
EngineEdition : 2              -- 2 = Standard; 4 would be Express
Version       : 16.0.1000.6    -- SQL Server 2022 RTM
```

Someone read the instance name as the edition. Since `ledger:refresh` is nothing but
`EXEC dbo.usp_RefreshFinanceLedgerSnapshot…`, moving it into Agent removed four layers that
bought nothing:

- **1,440 `php.exe` bootstraps a day** — a per-minute `schedule:run` to fire two fixed-time jobs.
- **A MySQL dependency on a SQL Server refresh.** `withoutOverlapping()` stores its lock in the
  default cache store, MySQL `cache_locks`. MySQL down blocked a job that never touches MySQL.
- **The scheduler task**, its 4-hour timeout, and that single blocking channel.
- **`EXECUTE` on a snapshot-rewriting proc held by the web-facing `finance` login.**

The job now runs with no dependency on the application at all — Apache can be stopped and the app
redeployed or deleted, and the snapshot still refreshes. The app discovers refreshes rather than
being notified of them: `VersionsLedgerCache` versions its cache keys off `RefreshedAt` read from
SQL Server.

**Overlap:** Agent will not start a job that is already running. That is the direct replacement
for `withoutOverlapping()`, and it is why this is **one job with one schedule** whose step
branches on day-of-month rather than two jobs — two jobs would each be individually guarded but
could still overlap each other. There is no `sp_getapplock` in the procs, so Agent's guard is the
only one.

> **Never re-register the Laravel schedule.** `routes/console.php` no longer contains a
> `Schedule::command()` entry. Adding one back while the Agent job exists double-schedules the
> same stored procedure with nothing at the SQL layer to stop the collision.

## What the two-server split changes

The app on one Windows server, SQL Server 2022 on another. The design holds — moving the refresh
into Agent is what made it hold — but four things are different, and only the first is obvious.

**1. The refresh is now genuinely independent.** It was already true on paper; with the boxes
separated it is true in practice. The web server can be rebuilt, redeployed, or switched off
entirely and the snapshot still refreshes at 21:30. Nothing in Part 1 steps 2 to 7 involves the
web server at any point.

**2. The monitoring gained a dependency the refresh shed.** The health check runs on the web
server and reads the DB server over the network. Web server down, *or the link down*, and you are
blind to data that is perfectly current. This is the argument for A2 (page up).

**3. There are two clocks now.** `RefreshedAt` comes from `SYSDATETIME()` on the DB server;
`ledger:status` compares it to `now()` on the web server. Same box, always consistent; different
boxes, only as consistent as you make them. Gated in step 1b.

**4. Failure modes that used to be distinct now look identical.** "Snapshot is stale" and "cannot
reach the database" both exit non-zero from `ledger:status` and produce the same alert text. The
distinguishing detail is in the logged output, not the subject line — see step 10.

And one non-change worth stating, because it is the reason step 8 still works: **`FinanceSvc` needs
no presence on the DB server.** Everything authenticates as the `finance` SQL login from `.env`,
so the local Windows identity never crosses the network. Had this design used Windows
authentication, splitting the boxes would have required a domain account and a rewrite of step 8.

## Why the health check is still a Windows task

Because the failure mode is silent:

> If the refresh stops, **nothing errors**. No exception, no warning banner, no failed request.
> Every page keeps loading fast and looking correct. The figures simply stop moving, and the gap
> widens by a day every day.

Database Mail is not configured, so a failed job is recorded in `sysjobhistory` and the Windows
event log and nowhere a human looks. And a *disabled* job never fails at all. Staleness has to be
asserted against the clock.

It also checks things that are not the database's business — Apache, disk space, log volume on
the **web** server. Different box, different failure domain, and nothing else watching it.

**The asymmetry to know:** the refresh no longer depends on the app, but the monitoring still
does — and since the split, on the network between them as well. Web server down (or link down) +
SQL fine = data stays current and you are blind to it. That is the argument for A2 alongside A1.

## Why 21:30

Evening, after the business day, rather than overnight. Everything else runs in the small hours:

```
01:15  Tue-Sat   Daily Backups.Subplan_1     (freq_interval 124 = Tue|Wed|Thu|Fri|Sat)
02:00  daily     syspolicy_purge_history
```

Plus Nexus on the same Windows box at 00:00, 01:00 and 02:00 daily, and 03:00 Sundays. The
monthly full rebuild starting 21:30 on the 1st runs to roughly 22:10, still hours clear of the
01:15 backup. See **F1** for the one assumption this rests on.

## Why daily *and* monthly

A fiscal period closes within its own month, so a monthly refresh on the 1st would satisfy the
reporting requirement on its own. **The daily run is for resilience, not freshness.** The sanity
gates deliberately keep the *previous* snapshot when a build looks wrong, so with a monthly-only
cadence one linked-server blip on the 1st means executives read last month's numbers for a month.
Daily turns one point of failure into ~30 chances, for 2-6 minutes a night. Closed fiscal years
never change, which is why the full loop is monthly.

## Manual runs

The Agent job handles the schedule. These are for one-offs, and **SSMS on the DB server is the
preferred way to do all of them.** Start the job, or run a single year directly:

```sql
EXEC msdb.dbo.sp_start_job @job_name = N'SWRHA Finance - Ledger Refresh';
EXEC dbo.usp_RefreshFinanceLedgerSnapshot @FinancialYear = '2026', @Force = 0;
```

`@Force = 1` bypasses the **movement** gates only. It never bypasses the zero-row gate.

### What `refresh-ledger.ps1` is actually for

Very little, and less than it used to be. It wraps `php artisan ledger:refresh`, which wraps
`EXEC dbo.usp_RefreshFinanceLedgerSnapshot` — the same proc the Agent job calls. It adds nothing
the two lines above do not do, and with the database on another box it does it worse (see Optional
B). It also stops working the moment you apply Optional B.

Keep it only for the initial production build, where a logged, unattended run from the app server
is convenient. **After go-live it is dead weight — retire it, along with `manage-ledger.bat`
options 2-5.** Nothing schedules it and nothing depends on it.

### What `check-ledger-health.ps1` is for — and why the Agent job cannot replace it

Keep this one. It is the scheduled task, and it is not redundant with the job:

> **The Agent job reports when a refresh fails. It has no way of reporting that it never ran.**

A job disabled during troubleshooting and never re-enabled, a job deleted, the Agent service left
on Manual after a reboot, or a job succeeding perfectly against a GL feed that stopped loading —
all four produce complete silence. And a failure is barely louder: without Database Mail it lands
in `sysjobhistory` and the Windows event log and nowhere a human looks.

Asserting staleness against the clock covers every one of those causes at once, which is the whole
argument for it. It also checks Apache, disk space and log volume on the **web** server — a
failure domain that, since the split, nothing else looks at at all.

**Could this move into SQL instead?** Yes, and it is a reasonable thing to add: a second Agent job
that raises an error when `MAX(RefreshedAt)` falls behind would assert the same fact from the DB
server, immune to the web tier and the network, and would compare two timestamps from one clock —
sidestepping the skew described in step 1b. But it needs Database Mail to be worth anything, it is
another job that can itself be disabled, and it cannot see Apache or the web server's disk. An
addition, not a replacement.

| Script | Notes |
|---|---|
| `check-ledger-health.ps1` | The scheduled task. `-MaxAgeHours` defaults to 36. **Keep** |
| `refresh-ledger.ps1` | `-Year 2026`, `-All`, `-Force`. ~90-110s **per fiscal year**. Requires `finance` to retain `EXECUTE`. **Retire after go-live** |

`scripts\manage-ledger.bat` is the menu wrapper. Options 6-7 target the health check task; the
Agent job is not startable from there (no SQL credentials, and `finance` cannot start jobs).

## Logs and records

Which box a record lives on matters as much as what it says — half of these are unreachable when
you are logged into the wrong one.

| Where | Box | What |
|---|---|---|
| `dbo.FinanceLedgerRefresh` | DB | **Authoritative** refresh history — rows, duration, totals, outcome, abort reason |
| `msdb.dbo.sysjobhistory` | DB | Agent's view: start, duration, success/failure, step output |
| Windows Application event log | DB | Job failures (`notify_level_eventlog = 2`) |
| `storage\logs\ledger-health-check.log` | Web | check-ledger-health.ps1 |
| `storage\logs\ledger\refresh-ledger-*.log` | Web | refresh-ledger.ps1 — manual runs only |
| `storage\logs\laravel.log` | Web | Laravel application |

## Coexistence with CFS and Nexus

| Concern | CFS | SWRHA Nexus | SWRHA Finance |
|---|---|---|---|
| Task Scheduler names | `Laravel Queue Worker` | `SWRHA Nexus - *` | `SWRHA Finance - Ledger Health Check` |
| Laravel `schedule:run` task | — | Yes | **None — schedule is in SQL Agent** |
| Queue worker | Yes | Yes | **None — dispatches no jobs** |
| Service account | — | `NexusSvc` | `FinanceSvc` |
| App database | `cfs` | `inventory-app` | `finance` |
| Cache prefix | — | — | `finance_automation_system_cache_` |
| Log files | `cfs\storage\logs\` | `nexus\storage\logs\` | `finance\storage\logs\` |

Moving to Agent removed the Windows-side collision — the old 02:00 daily landed on Nexus's
`gp:sync-reason-codes`. It also removed most of the reason to care: Finance's only remaining
Windows task is a sub-minute health check, and its real workload now runs on the DB server where
neither of the other apps has anything scheduled.

**Confirm whether Nexus and CFS are still co-resident with Finance.** If Finance now has the web
server to itself, this whole section is historical and the commands below have nothing to run
against. If they do share the box, check both before changing any timing:

```powershell
cd C:\Apache24\htdocs\production\nexus; php artisan schedule:list
cd C:\Apache24\htdocs\production\cfs;   php artisan schedule:list
```

Either way, the DB server's own schedule is the one that matters for the refresh — the 01:15
Tue-Sat `Daily Backups.Subplan_1` and the 02:00 `syspolicy_purge_history`.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `RefreshedAt` never advances | Job disabled/deleted, or Agent service stopped | `SELECT name, enabled FROM msdb.dbo.sysjobs`; check the service |
| Job fails with a login or delegation error | Agent account cannot use the `GPSWRHA` linked server | Steps 3 and 5. Add a login mapping |
| Job fails with `EXECUTE permission was denied` | Step 4 grants not applied, or wrong account name | Re-run step 4 with the real Agent account |
| `CREATE JOB` fails outright | `Agent XPs` disabled | `EXEC sp_configure 'Agent XPs', 1; RECONFIGURE;` |
| `Outcome = 'ABORTED'`, "Staging is empty" | Source returned nothing — usually the linked server | Check `GPSWRHA.SWRHA.CO.TT`. **Do not force**; the gate is protecting good data |
| `Outcome = 'ABORTED'`, "Total allocation/YTD moved…" | >25% movement — normal when a new FY opens or after a bulk reallocation | Confirm genuine, then `@Force = 1` |
| Figures are exactly one day behind, every day | The GL load runs overnight, after 21:30 | See **F1** — move the schedule later |
| Two refreshes ran at once | A Laravel `Schedule::command()` entry was re-added | Remove it. Agent guards itself; it cannot guard against a second scheduler |
| Health check reports fresh while the job is disabled | Expected for up to `-MaxAgeHours` (36) — it asserts staleness against the clock | Wait, or apply Optional C |
| Health check task returns `0x1` | PHP not on `FinanceSvc`'s PATH | Use the full path to `php.exe`, or fix the account's PATH |
| Pages show stale dropdowns | Filter caches on the `file` store | `php artisan cache:clear file` — plain `cache:clear` does **not** touch them |
| Health check logs `Could not read dbo.FinanceLedgerRefresh` | **Connectivity, not staleness.** The web server cannot reach the DB server | Step 1b: firewall, TCP/IP, port, ODBC driver, SQL service. The refresh is probably fine — check `FinanceLedgerRefresh` from SSMS before touching the job |
| Alerts fire nightly but `FinanceLedgerRefresh` looks healthy | Clock skew between the boxes inflating the computed age | Step 1b. Align timezone and NTP on both |
| Ages look plausible but staleness is never caught | Skew the other way — the DB server's clock is ahead, so refreshes read younger than they are | Step 1b |
| App shows no data while the job reports `OK` | `SQLSRV_HOST` pointing at `localhost` / an instance on the web server | Step 1. It must be the DB server |
| Job runs and succeeds but nothing changes | Job created on the wrong instance | Step 2's `SERVERPROPERTY('MachineName')` check |
| Long manual `ledger:refresh` dies part-way | Connection dropped in transit — an idle/NAT timeout a local connection never met | Run it from SSMS on the DB server instead (Manual runs) |
