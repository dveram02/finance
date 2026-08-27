# Database Mail — SSMS walkthrough

Step-by-step configuration of Database Mail and job alerting on `sqlapp\SQLEXPRESS`, entirely
through the SSMS user interface. Companion to `sql/FinanceDatabaseMail.sql`, which does the same
thing in T-SQL.

**Everything here is on the DB server.** Connect in SSMS as a **sysadmin** — Database Mail is a
sysadmin-only feature, and the menu items below are absent or greyed out otherwise.

| | |
|---|---|
| **Delivers** | Email when the job `SWRHA Finance - Ledger Refresh` runs and fails |
| **Does not deliver** | Any alert when the job *never runs* — see the gap below |
| **Replaces** | Sections 2, 3, 5 and 6 of `sql/FinanceDatabaseMail.sql` |
| **Does NOT replace** | Sections 4b, 6's operator test, and 7 of that file — see the last section here |
| **Time** | ~15 minutes, plus one SQL Agent restart |

> **The instance is *named* `SQLEXPRESS` but its edition is Standard 2022.** That matters here:
> Database Mail genuinely is not available on Express, so the name alone suggests this cannot
> work. If anyone doubts it, settle it with `SELECT SERVERPROPERTY('Edition');`

**Written against SSMS 19.x ("SSMS 2022") connected to SQL Server 2022 Standard.** The dialogs
below have been stable since SSMS 17 — the wizard's six pages, the Agent *Alert System* page, the
Operator dialog and the job *Notifications* page are unchanged across SSMS 17–20. If you are on a
different build and a dialog does not match, the field names still will; only the chrome moved.

Two things that trip people up but are **not** Database Mail problems:

* **SSMS version ≠ SQL Server version.** SSMS 19 managing SQL Server 2022 is the normal pairing;
  nothing here depends on the SSMS build.
* **On SSMS 20 and later**, new connections default to `Encrypt = Mandatory`, so you may be asked
  to trust the server certificate when you connect. That is a *connection* setting, not a mail
  setting — it has no bearing on anything below.

---

## What you need before you start

Ask whoever runs mail. Guessing produces a message that queues, never arrives, and leaves an
empty error log.

| | Example | Notes |
|---|---|---|
| SMTP server | `smtp.swrha.co.tt` | |
| Port | `25` or `587` | 25 = plain relay, 587 = TLS |
| Authentication | anonymous **or** basic | see A1 |
| From address | `sqlalerts@swrha.co.tt` | must be permitted to send |
| Recipient | `finance-alerts@swrha.co.tt` | **prefer a distribution list** — see A4 |

---

## What this does and does not cover

Read this before deciding it is sufficient on its own.

| Failure | Database Mail | Health check task |
|---|---|---|
| A sanity gate aborts a step | ✅ | ✅ |
| Step 2 fails, step 1 succeeded | ✅ | ✅ (drift) |
| **SQL Agent service stopped** | ❌ | ✅ |
| **The job is disabled** | ❌ | ✅ |
| **The job is deleted** | ❌ | ✅ |

Database Mail can only alert on a job that **fires**. A disabled job never fails, so it never
emails — and the figures go stale in exactly the same way. **This does not replace
`scripts/check-ledger-health.ps1` on the web server** (register it with
`scripts/register-health-check-task.ps1`). The two cover different halves, and the half this
cannot see is the one that fails silently.

---

## A1 — Run the Database Mail Configuration Wizard

*Replaces sections 2 and 3 of the SQL file.*

**Object Explorer → Management → right-click `Database Mail` → Configure Database Mail**

### Welcome page
→ **Next**

### Select Configuration Task
- **(•) Set up Database Mail by performing the following tasks**
- → **Next**

If prompted *"The Database Mail feature is not available. Would you like to enable this
feature?"* → **Yes**. That is the wizard running section 2's `sp_configure` for you.

### New Profile

| Field | Value |
|---|---|
| Profile name | `SWRHA Finance Alerts` |
| Description | `SWRHA Finance alerting profile` |

Then **SMTP accounts → Add…**

### New Database Mail Account dialog

| Field | Value |
|---|---|
| Account name | `SWRHA Finance Alerts` |
| Description | `Alerts from the SWRHA Finance refresh job` |

**Outgoing Mail Server (SMTP)**

| Field | Value |
|---|---|
| E-mail address | your *from* address |
| Display name | `SWRHA Finance (SQL Server)` |
| Reply e-mail | blank, or a monitored mailbox |
| Server name | your SMTP server |
| Port number | `25` (relay) or `587` (authenticated) |
| ☐ This server requires a secure connection (SSL) | **tick for 587/TLS**, clear for plain 25 |

**SMTP Authentication** — pick one, matching your mail team's answer:

- **(•) Anonymous authentication** — the internal-relay case. Nothing to store, nothing to rotate.
- **(•) Basic authentication** — user name / password / confirm. The Microsoft 365 case. Note M365
  needs SMTP AUTH enabled on the mailbox or a connector; a plain user password often will not work.
- **( ) Windows Authentication using Database Engine service credentials** — almost never right
  here. It authenticates as the SQL Server service account, which mail servers rarely accept.

→ **OK**, then → **Next**

### Manage Profile Security

**Public** tab:
- ☑ `SWRHA Finance Alerts` (tick the box in the left column)
- **Default Profile** → change to **Yes**

Leave the **Private** tab alone.

→ **Next**

> ### ⚠ Do not skip this page
> A profile that is not **public *and* default** will not appear in the SQL Agent *Alert System*
> dropdown in A3. You will be left staring at an empty list with nothing on screen explaining why.

### Configure System Parameters

Defaults are fine. Two worth knowing:

- **Logging Level** → set to **Verbose** while setting this up, then put it back to **Extended**.
  Verbose is noisy but tells you what actually happened.
- **Account Retry Attempts / Retry Delay** → 1 and 60s is fine here.

→ **Next**

### Complete the Wizard
→ **Finish**

**Every line must read `Success`.** Read them — the wizard reports partial failure without
stopping. → **Close**

---

## A2 — Send a test message

*Partially replaces section 4.*

**Object Explorer → Management → right-click `Database Mail` → Send Test E-Mail…**

| Field | Value |
|---|---|
| Database Mail Profile | `SWRHA Finance Alerts` |
| To | your recipient address |
| Subject / Body | leave the defaults |

→ **Send Test E-Mail**

> ### ⚠ The confirmation dialog is not proof of delivery
> It tells you the message was handed to the queue — exactly as `sp_send_dbmail` does. **Queued is
> not sent.**

If it does not arrive within a minute:

**right-click `Database Mail` → View Database Mail Log**

That is the GUI form of section 4b's `sysmail_event_log` query, and it carries the real SMTP
error.

| Log message | Means |
|---|---|
| `Cannot send mails to mail server. (Failure sending mail.)` | Wrong server/port, or the firewall blocks outbound SMTP from the DB box |
| `The server rejected the sender address` | Your *from* address is not permitted to send. Ask the mail team |
| `5.7.1 Client was not authenticated` / `Relay access denied` | The relay wants credentials — redo A1 with **Basic authentication** |
| Status stays `unsent` with **no** log rows | The Database Mail external program is not starting. Check `DatabaseMail.exe` exists in the instance BINN folder and that Database Mail XPs is enabled |

---

## A3 — Point SQL Agent at the profile

*Replaces section 5.* **This is the most commonly missed step.**

Database Mail can work perfectly — A2 arrives, the log is clean — while the **job still emails
nobody**, because SQL Agent keeps its own separate mail setting.

**Object Explorer → right-click `SQL Server Agent` → Properties → `Alert System` page**

- ☑ **Enable mail profile**
- **Mail system**: `Database Mail`
- **Mail profile**: `SWRHA Finance Alerts`
- ☑ Save copies of the sent messages in the Sent Items folder *(optional)*

→ **OK**

> **If the Mail profile dropdown is empty**, the profile is not public+default. Go back to A1's
> *Manage Profile Security* page and fix it. Reopening SSMS sometimes clears a stale list.

Then: **right-click `SQL Server Agent` → Restart**

> ### ⚠ The setting does not apply until Agent restarts
> Skipping the restart is how this ends up configured-but-silent.

---

## A4 — Create the operator

*Replaces section 6a.*

An **operator** is SQL Agent's name for a notification recipient — a label plus an email address.
It is not a login and carries no permissions. Jobs reference it by name, so the recipient lives in
one place.

**Object Explorer → SQL Server Agent → right-click `Operators` → New Operator…**

| Field | Value |
|---|---|
| Name | `Finance Admin` |
| ☑ Enabled | **must be ticked** |
| E-mail name | `finance-alerts@swrha.co.tt` |

→ **OK**

Two things worth getting right:

- **Prefer a distribution list to a personal mailbox.** A personal address stops alerting the day
  that person is on leave or changes team. Multiple recipients are semicolon-separated:
  `finance-alerts@swrha.co.tt;itsupport@swrha.co.tt`
- **`Enabled` unticked is a silent kill switch.** The job still records that it notified, and
  nothing arrives.

Leave the pager and net-send fields blank; they are vestigial.

---

## A5 — Attach the operator to the job

*Replaces section 6b.*

**Object Explorer → SQL Server Agent → Jobs → right-click `SWRHA Finance - Ledger Refresh` →
Properties → `Notifications` page**

- ☑ **E-mail** → `Finance Admin` → **When the job fails**
- ☑ **Write to the Windows Application event log** → **When the job fails**

→ **OK**

> **"When the job fails", not "When the job completes".** A success email every night at 21:30 is
> how people learn to filter these into a folder they never open.

If the **E-mail** row is greyed out, A3 has not been done, or Agent has not been restarted.

---

## A6 — Read back what you built

**Jobs → right-click the job → Properties → Notifications** should read `Finance Admin` /
*When the job fails*.

The T-SQL read-back in section 6 of `sql/FinanceDatabaseMail.sql` shows the same thing in one row,
which is easier to paste into a change record:

```sql
SELECT j.name AS job_, j.enabled, j.notify_level_email, o.name AS operator_, o.email_address
FROM msdb.dbo.sysjobs j
LEFT JOIN msdb.dbo.sysoperators o ON o.id = j.notify_email_operator_id
WHERE j.name = N'SWRHA Finance - Ledger Refresh';
```

---

## ⚠ What the GUI cannot do — go back to the T-SQL for these

You are not finished after A6. Three things have **no** SSMS equivalent, and each of them is a way
for this to look configured while alerting nobody.

### 1. Test the operator path

There is no "send test" on an operator in SSMS. A2 tested **Database Mail**; it did **not** test
Agent's own lookup-and-send, which is the path a real failure uses. Run from section 6, **after**
the A3 restart or it proves nothing:

```sql
EXEC msdb.dbo.sp_notify_operator
     @name    = N'Finance Admin',
     @subject = N'SWRHA Finance - Agent operator test',
     @body    = N'Sent via sp_notify_operator. If this arrives, SQL Agent alerting is live.';
```

### 2. Prove the whole chain end to end

Nothing in the GUI makes the job fail on purpose. **Section 7** of `sql/FinanceDatabaseMail.sql`
adds a temporary always-failing step, runs the job, and removes it. Everything above can pass
while the job still alerts no one — section 7 is the only test that rules that out.

**Do not skip section 7c.** A left-behind failing step means the job reports failure every night
forever.

### 3. Roll back cleanly

Section 8 is scripted. Unpicking this through the GUI means remembering every dialog you touched.

---

## Recommendation

Use the GUI for A1–A5 if you prefer it — it is the same configuration either way. Then run
**section 4b**, **section 6's `sp_notify_operator` test** and **section 7** as T-SQL.

**Setup is a matter of taste. Verification is not.**

---

## Reference

| File | What it is |
|---|---|
| `sql/FinanceDatabaseMail.sql` | The same configuration in T-SQL, plus the three verification steps above |
| `scripts/register-health-check-task.ps1` | The other half of alerting — catches the job that never runs |
| `scripts/check-ledger-health.ps1` | What that task runs |
| `instructionsphase2.md` | The Phase 2 production runbook; this is its Step 9b |
| `sql/FinanceLedgerAgentJob.sql` | The Agent job itself. Appendix B sketched this before it was built out |
