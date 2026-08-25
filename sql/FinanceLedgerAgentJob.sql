/* ===========================================================================
   SWRHA Finance — SQL Server Agent job for the ledger snapshot refresh
   ---------------------------------------------------------------------------
   Creates the job `SWRHA Finance - Ledger Refresh` on sqlapp\SQLEXPRESS.

   ** DO NOT EXECUTE THIS FILE TOP TO BOTTOM. **

   Run one section at a time, in order, following Part 1 of
   instructionsforschedule.md. Sections 2 and 4 are GATES: they are meant to
   fail before anything is created. Executing the whole file would build the job
   before the linked-server gate has been cleared, which is the one failure this
   layout exists to prevent.

   Connect as a SYSADMIN login. The application's `finance` login cannot run any
   of this and should not be able to.

   SECTION MAP — sections are numbered in the order you run them, and each maps
   to a step in instructionsforschedule.md Part 1:

     Section 1   Runbook step 2   Agent service account name
     Section 2   Runbook step 3   GATE — linked server login mapping
     Section 3   Runbook step 4   Grants for the Agent account
     Section 4   Runbook step 5   GATE — Agent account can read GP
     Section 5   Runbook step 6   Create the job
     Section 6   Runbook step 7   Start it once and verify
     Section 7   Follow-up F1     Find the GL load window
     Section 8   —                Rollback

     Appendix A  Optional D       sp_getapplock hardening (unapplied)
     Appendix B  Optional A2      Database Mail, for job-failure email
     Appendix C  —                Building the job through the SSMS GUI instead
     Appendix D  Optional B       Revoke EXECUTE from the `finance` login

   The rationale for using Agent at all — and why there is no longer a Laravel
   schedule — is in instructionsforschedule.md Part 4. The short version: the
   instance is merely NAMED SQLEXPRESS; its edition is Standard 2022, Agent is
   running, and this job is nothing but an EXEC of a stored procedure.

   OVERLAP: Agent will not start a job that is already running. That replaces
   withoutOverlapping(), and it is why this is ONE job with ONE schedule whose
   step branches on day of month rather than two jobs — two jobs would each be
   individually guarded but could still overlap each other. There is no
   sp_getapplock in the procs, so Agent's guard is the only one.
   =========================================================================== */


/* ===========================================================================
   SECTION 1 — Agent service account name          [runbook step 2]
   ---------------------------------------------------------------------------
   Write down the service_account value. Sections 3 and 4 both need it.
   Expect status_desc = Running and startup_type_desc = Automatic.
   =========================================================================== */
SELECT servicename, service_account, status_desc, startup_type_desc
FROM sys.dm_server_services
WHERE servicename LIKE 'SQL Server Agent%';
GO


/* ===========================================================================
   SECTION 2 — OBSOLETE since 2026-08-25: linked server login mapping
   ---------------------------------------------------------------------------
   *** THIS GATE NO LONGER APPLIES. SKIP IT. ***

   fn_FinanceLedgerSource was rewritten to read the chart of accounts from the
   LOCAL mirror (0030ADGPCOA + 0030AEAccountNameCorrections). It no longer
   touches [GPSWRHA.SWRHA.CO.TT] at all, so the Agent service account needs no
   linked-server login mapping, and the failure this gate existed to prevent
   cannot occur. Retained so the runbook's step numbering still resolves.

   The ORIGINAL gate text follows, for reference only.
   ---------------------------------------------------------------------------
   SECTION 2 — GATE: linked server login mapping   [runbook step 3]
   ---------------------------------------------------------------------------
   fn_FinanceLedgerSource reads [GPSWRHA.SWRHA.CO.TT].[SWRHA].[dbo].[GL40200]
   and [DBA_Clusters]. How that linked server maps logins decides whether the
   Agent account can do the same thing the `finance` login can.

     local_principal_id = 0, uses_self_credential = 0, remote_name set
         -> fixed remote login for everyone. Good. Continue.

     uses_self_credential = 1
         -> pass-through. Works for `finance`, will FAIL for the Agent account.
            Add a mapping for the Agent account before going further.

   GUI equivalent: Server Objects > Linked Servers > GPSWRHA.SWRHA.CO.TT >
   Properties > Security. "Be made using the login's current security context"
   is the setting that breaks it.
   =========================================================================== */
SELECT s.name AS linked_server, l.local_principal_id,
       l.uses_self_credential, l.remote_name
FROM sys.servers s
LEFT JOIN sys.linked_logins l ON l.server_id = s.server_id
WHERE s.is_linked = 1;
GO


/* ===========================================================================
   SECTION 3 — Grants for the Agent account        [runbook step 4]
   ---------------------------------------------------------------------------
   The job step runs as the SQL Agent service account: the job owner is sa and
   the step is T-SQL, so no proxy is involved.

   Uncomment the block and replace the account name with the value from
   section 1 — typically NT SERVICE\SQLAgent$SQLEXPRESS. Skip CREATE LOGIN if
   the login already exists.
   =========================================================================== */
USE FinanceAutomationSystem;
GO

-- CREATE LOGIN [NT SERVICE\SQLAgent$SQLEXPRESS] FROM WINDOWS;
-- CREATE USER  [NT SERVICE\SQLAgent$SQLEXPRESS] FOR LOGIN [NT SERVICE\SQLAgent$SQLEXPRESS];
-- GRANT EXECUTE ON dbo.usp_RefreshFinanceLedgerSnapshot    TO [NT SERVICE\SQLAgent$SQLEXPRESS];
-- GRANT EXECUTE ON dbo.usp_RefreshFinanceLedgerSnapshotAll TO [NT SERVICE\SQLAgent$SQLEXPRESS];
-- ALTER ROLE db_datareader ADD MEMBER [NT SERVICE\SQLAgent$SQLEXPRESS];
-- GRANT INSERT, DELETE ON dbo.FinanceLedgerSnapshot         TO [NT SERVICE\SQLAgent$SQLEXPRESS];
-- GRANT INSERT, DELETE ON dbo.FinanceLedgerSnapshot_Staging TO [NT SERVICE\SQLAgent$SQLEXPRESS];
-- GRANT INSERT, UPDATE ON dbo.FinanceLedgerRefresh          TO [NT SERVICE\SQLAgent$SQLEXPRESS];
GO


/* ===========================================================================
   SECTION 4 — GATE: can the Agent account read GP?   [runbook step 5]
   ---------------------------------------------------------------------------
   ** THE MOST LIKELY FAILURE OF THIS WHOLE SETUP. **

   Both tables below are the ones fn_FinanceLedgerSource actually reads across
   the linked server. Expect one row from each.

   HOW TO READ THE RESULT:

     One row from each                  -> PASS. Continue to section 5.

     Msg 7416 / 18456 / 15404, "Access
     to the remote server is denied",
     or an SSPI / delegation error      -> FAIL. Go back to section 2 and add a
                                           linked-server mapping for the Agent
                                           account.

     Msg 207 "Invalid column name"      -> the CONNECTION worked; only the column
                                           list is wrong. Binding a four-part
                                           name requires fetching remote
                                           metadata, so reaching this error means
                                           authentication succeeded. Fix the
                                           column list and re-run to confirm.

   Do not skip this and create the job anyway. A linked-server permission
   failure surfaces in the job history looking like a data error, hours later.

   Uncomment and substitute the account name from section 1.
   =========================================================================== */
-- EXECUTE AS LOGIN = 'NT SERVICE\SQLAgent$SQLEXPRESS';
-- SELECT TOP 1 SGMTNUMB, SGMNTID, DSCRIPTN
--     FROM [GPSWRHA.SWRHA.CO.TT].[SWRHA].[dbo].[GL40200];
-- SELECT TOP 1 * FROM [GPSWRHA.SWRHA.CO.TT].[SWRHA].[dbo].[DBA_Clusters];
-- REVERT;
GO


/* ===========================================================================
   SECTION 5 — Create the job                      [runbook step 6]
   ---------------------------------------------------------------------------
   Idempotent: drops any previous version first, so it is safe to re-run.
   Run 5a through 5d together.

   Prefer the GUI? Appendix C is the full New Job dialog walkthrough — but use
   the GUI STEP COMMAND block there, NOT the @command text in 5b.
   =========================================================================== */
USE msdb;
GO

-- ---- 5a. Drop any previous version -----------------------------------------
IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'SWRHA Finance - Ledger Refresh')
    EXEC msdb.dbo.sp_delete_job @job_name = N'SWRHA Finance - Ledger Refresh', @delete_unused_schedule = 1;
GO

/* ---- 5b. The job -----------------------------------------------------------
   notify_level_eventlog = 2 writes a Windows Application event-log entry on
   failure. Database Mail is NOT configured on this instance, so that entry and
   dbo.FinanceLedgerRefresh are the only failure records — which is exactly why
   the Windows health-check task is mandatory, not optional. Appendix B if that
   changes.
   --------------------------------------------------------------------------- */
EXEC msdb.dbo.sp_add_job
    @job_name    = N'SWRHA Finance - Ledger Refresh',
    @enabled     = 1,
    @description = N'Rebuilds dbo.FinanceLedgerSnapshot. Current + prior fiscal year daily; every fiscal year on the 1st. Source of all data on the Finance portal.',
    @owner_login_name    = N'sa',
    @notify_level_eventlog = 2;   -- 2 = on failure
GO

/* ---- 5c. The step ----------------------------------------------------------
   The fiscal-year expression mirrors App\Concerns\ResolvesFiscalYear and
   RefreshFinanceLedger::recentYears(): a fiscal year runs Oct 1 -> Sep 30 and
   is named for the year it ENDS in, so October rolls the window forward.

   @FromYear = current - 1 reproduces FINANCE_LEDGER_REFRESH_RECENT_YEARS=2.
   If you change that env value, change the arithmetic here to match — this is
   now the authoritative copy, config/ledger.php no longer drives the schedule.

   Using ...All with @FromYear rather than naming the years explicitly is
   deliberate: it only refreshes years actually present in the source, so early
   in a new fiscal year (October, before the first postings) the job skips the
   empty year instead of tripping the zero-row gate and reporting failure.
   --------------------------------------------------------------------------- */
EXEC msdb.dbo.sp_add_jobstep
    @job_name   = N'SWRHA Finance - Ledger Refresh',
    @step_name  = N'Refresh snapshot',
    @subsystem  = N'TSQL',
    @database_name = N'FinanceAutomationSystem',
    @retry_attempts = 2,
    @retry_interval = 20,          -- minutes; retained for transient DB errors
    @on_success_action = 1,        -- quit reporting success
    @on_fail_action    = 2,        -- quit reporting failure
    @command = N'
SET NOCOUNT ON;

DECLARE @today  date = CONVERT(date, SYSDATETIME());
DECLARE @currFY int  = CASE WHEN MONTH(@today) >= 10 THEN YEAR(@today) + 1 ELSE YEAR(@today) END;

IF DAY(@today) = 1
BEGIN
    -- Full rebuild, every fiscal year. 16-38 minutes.
    -- Closed fiscal years never change, which is why this is monthly and not nightly.
    RAISERROR(''Finance ledger: full rebuild (all fiscal years).'', 0, 1) WITH NOWAIT;
    EXEC dbo.usp_RefreshFinanceLedgerSnapshotAll @Force = 0;
END
ELSE
BEGIN
    -- Current + prior fiscal year. 2-6 minutes.
    -- Daily is for RESILIENCE, not freshness: the sanity gates keep the previous
    -- snapshot when a build looks wrong, so a monthly-only cadence would let one
    -- bad run leave the figures stale for up to 31 days.
    DECLARE @fromYear varchar(10) = CONVERT(varchar(10), @currFY - 1);
    RAISERROR(''Finance ledger: refreshing FY%s onward.'', 0, 1, @fromYear) WITH NOWAIT;
    EXEC dbo.usp_RefreshFinanceLedgerSnapshotAll @FromYear = @fromYear, @Force = 0;
END
';
GO

/* ---- 5d. The schedule: daily 21:30 -----------------------------------------
   Evening, after the business day, rather than overnight. Everything else on
   this server runs in the small hours:

     01:15 Tue-Sat  Daily Backups.Subplan_1   (freq_interval 124 = Tue|Wed|Thu|Fri|Sat)
     02:00 daily    syspolicy_purge_history
     00:00 / 01:00 / 02:00 daily, 03:00 Sundays   SWRHA Nexus, same Windows box

   The monthly full rebuild starting 21:30 on the 1st runs to roughly 22:10,
   still hours clear of the 01:15 backup.

   ONE ASSUMPTION: that the external process writing dbo.0098AFinGLMaster runs
   during the business DAY. An evening slot is specifically sensitive to this —
   if that load runs overnight, a 21:30 refresh reads the table before the
   night's load lands and the snapshot sits a full day behind, permanently and
   silently. Section 7 settles it.
   --------------------------------------------------------------------------- */
EXEC msdb.dbo.sp_add_jobschedule
    @job_name       = N'SWRHA Finance - Ledger Refresh',
    @name           = N'Daily 21:30',
    @freq_type      = 4,        -- daily
    @freq_interval  = 1,        -- every day
    @active_start_time = 213000;
GO

EXEC msdb.dbo.sp_add_jobserver
    @job_name    = N'SWRHA Finance - Ledger Refresh',
    @server_name = N'(LOCAL)';
GO


/* ===========================================================================
   SECTION 6 — Start it once and verify            [runbook step 7]
   ---------------------------------------------------------------------------
   Unless today is the 1st, expect 2-6 minutes. Watch it in SSMS under
   SQL Server Agent > Job Activity Monitor.
   =========================================================================== */

-- ---- 6a. Start the job (GUI: right-click the job > Start Job at Step...) ----
-- EXEC msdb.dbo.sp_start_job @job_name = N'SWRHA Finance - Ledger Refresh';

-- ---- 6b. Outcome, Agent's view (GUI: right-click > View History) -----------
SELECT j.name,
       msdb.dbo.agent_datetime(h.run_date, h.run_time) AS started,
       h.run_duration,     -- HHMMSS
       h.run_status,       -- 0 failed, 1 succeeded, 3 cancelled, 4 in progress
       h.message
FROM msdb.dbo.sysjobhistory h
JOIN msdb.dbo.sysjobs j ON j.job_id = h.job_id
WHERE j.name = N'SWRHA Finance - Ledger Refresh'
ORDER BY h.run_date DESC, h.run_time DESC;

/* ---- 6c. Outcome, the authoritative record --------------------------------
   This is what `php artisan ledger:status` reads. Expect Outcome = 'OK' and a
   RefreshedAt from the last few minutes.

   Outcome = 'ABORTED' means a sanity gate held the previous snapshot ON PURPOSE.
   Read the Message before forcing anything.
   --------------------------------------------------------------------------- */
SELECT FinancialYear, RefreshedAt, RowsLoaded, DurationSeconds,
       TotalAllocation, TotalYTD, Outcome, Message
FROM FinanceAutomationSystem.dbo.FinanceLedgerRefresh
ORDER BY FinancialYear;
GO


/* ===========================================================================
   SECTION 7 — Find the GL load window             [runbook follow-up F1]
   ---------------------------------------------------------------------------
   Not part of setup. Do it in the first week.

   No Agent job on this instance writes dbo.0098AFinGLMaster — a search of
   sysjobsteps for 0098A / GPSWRHA / GL returns nothing — and the table is LOCAL
   to FinanceAutomationSystem (only GL40200 and DBA_Clusters come across the
   linked server). So something external writes it, on an unconfirmed schedule.

   Daytime load  -> 21:30 sits after it. Correct.
   Overnight load -> 21:30 reads before it. Snapshot is a full day behind, and
                     nothing reports it: RefreshedAt still advances every night.
   =========================================================================== */

-- ---- 7a. When was the table last written? ----------------------------------
--        Resets on service restart, so sample over a few days rather than
--        trusting a single reading.
SELECT OBJECT_NAME(object_id) AS table_name,
       last_user_insert, last_user_update
FROM sys.dm_db_index_usage_stats
WHERE database_id = DB_ID('FinanceAutomationSystem')
  AND object_id   = OBJECT_ID('FinanceAutomationSystem.dbo.[0098AFinGLMaster]');

-- ---- 7b. Does the table carry its own timestamp? ---------------------------
--        If it does, the distribution of the newest values gives the window
--        directly.
SELECT c.name, t.name AS data_type
FROM sys.columns c
JOIN sys.types   t ON t.user_type_id = c.user_type_id
WHERE c.object_id = OBJECT_ID('FinanceAutomationSystem.dbo.[0098AFinGLMaster]')
  AND t.name IN ('date','datetime','datetime2','smalldatetime');
GO


/* ===========================================================================
   SECTION 8 — Rollback
   ---------------------------------------------------------------------------
   Removes the job entirely. The snapshot and all data are untouched.
   =========================================================================== */
-- USE msdb;
-- EXEC msdb.dbo.sp_delete_job @job_name = N'SWRHA Finance - Ledger Refresh',
--                             @delete_unused_schedule = 1;


/* ===========================================================================
   APPENDIX A — optional: sp_getapplock hardening   [runbook Optional D]
   ---------------------------------------------------------------------------
   Agent already prevents this job from overlapping itself. This only adds
   protection against a manual SSMS run landing on top of a scheduled one.

   If you want it, add this to the TOP of usp_RefreshFinanceLedgerSnapshot,
   immediately after SET XACT_ABORT ON, and release it before every exit path:

       DECLARE @lock int;
       EXEC @lock = sp_getapplock
           @Resource   = 'FinanceLedgerRefresh',
           @LockMode   = 'Exclusive',
           @LockOwner  = 'Session',
           @LockTimeout = 0;
       IF @lock < 0
           THROW 51004, 'usp_RefreshFinanceLedgerSnapshot: another refresh is already running.', 1;

   Note the interaction with usp_RefreshFinanceLedgerSnapshotAll: it calls the
   single-year proc in a loop on the SAME session, and a session-owned lock is
   re-entrant for its owner, so the loop is unaffected. But every exit path
   (including the two THROWs) must call sp_releaseapplock, or the lock survives
   until the connection closes. Harmless for Agent, where each step is its own
   session; NOT harmless for a pooled application connection.

   Deliberately left unapplied: it edits a working production proc for a risk
   the job schedule no longer has.
   =========================================================================== */


/* ===========================================================================
   APPENDIX B — optional: Database Mail             [runbook Optional A2]
   ---------------------------------------------------------------------------
   Database Mail is currently OFF on this instance. Without it, a failed job is
   recorded in sysjobhistory and the Windows Application event log and nowhere a
   human will look. Its advantage over the health check's own SMTP is that it
   survives the web server being down — which is exactly when that is blind.

       EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
       EXEC sp_configure 'Database Mail XPs', 1;     RECONFIGURE;

       EXEC msdb.dbo.sysmail_add_account_sp
            @account_name = 'SWRHA Alerts', @email_address = 'alerts@swrha.com',
            @mailserver_name = 'your.smtp.server', @port = 587, @enable_ssl = 1,
            @username = 'alerts@swrha.com', @password = '<secret>';
       EXEC msdb.dbo.sysmail_add_profile_sp
            @profile_name = 'SWRHA Alerts';
       EXEC msdb.dbo.sysmail_add_profileaccount_sp
            @profile_name = 'SWRHA Alerts', @account_name = 'SWRHA Alerts', @sequence_number = 1;

   Point Agent at the profile (SQL Server Agent > Properties > Alert System >
   Enable mail profile), restart the Agent service, then:

       EXEC msdb.dbo.sp_add_operator
            @name = 'Finance Admin', @email_address = 'admin@swrha.com';
       EXEC msdb.dbo.sp_update_job
            @job_name = N'SWRHA Finance - Ledger Refresh',
            @notify_level_email = 2,               -- on failure
            @notify_email_operator_name = 'Finance Admin';

   Even with this enabled, keep the health check. A job that is DISABLED never
   fails, so it never sends mail — and the data goes stale exactly the same way.
   =========================================================================== */


/* ===========================================================================
   APPENDIX C — building the job through the SSMS GUI
   ---------------------------------------------------------------------------
   Replaces SECTION 5 only. Sections 1-4 and 6-7 still have to be run as T-SQL,
   with one exception noted below.

   Connect to sqlapp\SQLEXPRESS as a sysadmin. If the "SQL Server Agent" node is
   missing from Object Explorer, you are not sysadmin or the service is stopped.

   Object Explorer > SQL Server Agent > Jobs > right-click > New Job...

   GENERAL page
     Name        : SWRHA Finance - Ledger Refresh
     Owner       : sa
     Category    : [Uncategorized (Local)]
     Description : Rebuilds dbo.FinanceLedgerSnapshot. Current + prior fiscal
                   year daily; every fiscal year on the 1st. Source of all data
                   on the Finance portal.
     Enabled     : ticked

   STEPS page > New...
     Step name   : Refresh snapshot
     Type        : Transact-SQL script (T-SQL)
     Run as      : leave blank (T-SQL steps run as the job owner; a proxy is
                   only needed for CmdExec/PowerShell subsystems)
     Database    : FinanceAutomationSystem
     Command     : paste the GUI STEP COMMAND block at the end of this appendix

     ** Use that block, NOT the @command text in section 5c. ** 5c lives inside
     an N'...' literal, so its RAISERROR strings carry DOUBLED single quotes to
     escape them. Pasted into the GUI they would execute literally.

     Then the step's Advanced page:
       On success action   : Quit the job reporting success
       On failure action   : Quit the job reporting failure
       Retry attempts      : 2
       Retry interval (min): 20

   SCHEDULES page > New...
     Name             : Daily 21:30
     Schedule type    : Recurring
     Enabled          : ticked
     Frequency        : Daily,  Recurs every 1 day
     Daily frequency  : Occurs once at 21:30:00
     Duration         : Start date today, No end date

   NOTIFICATIONS page
     Tick "Write to the Windows Application event log" > When the job fails.
     The e-mail option is unavailable until Database Mail is configured
     (Appendix B).

   TARGETS page
     Target local server (the default).

   BEFORE CLICKING OK: use the "Script" button at the top of the dialog >
   "Script Action to New Query Editor Window" and diff it against section 5.
   Cheapest way to catch a mistyped schedule or a missed retry setting, and it
   leaves you a scripted copy of what you actually built.

   GUI EQUIVALENTS FOR THE OTHER SECTIONS
     Section 2 (linked server) : Server Objects > Linked Servers >
                                 GPSWRHA.SWRHA.CO.TT > Properties > Security.
                                 "Be made using the login's current security
                                 context" is the setting that breaks the Agent
                                 account. A real alternative to the query.
     Section 3 (grants)        : possible via Security > Logins > New Login and
                                 the Securables page, but it is six lines of
                                 T-SQL and far easier to get right in a query.
     Section 4 (EXECUTE AS)    : none. Run it as T-SQL. Do not skip it.
     Section 6a (start job)    : right-click the job > Start Job at Step...
     Section 6b (history)      : right-click the job > View History
     Watch a live run          : SQL Server Agent > Job Activity Monitor
     Section 7 (GL window)     : none.

   -- ====================== GUI STEP COMMAND (paste this) ======================
SET NOCOUNT ON;

DECLARE @today  date = CONVERT(date, SYSDATETIME());
DECLARE @currFY int  = CASE WHEN MONTH(@today) >= 10 THEN YEAR(@today) + 1 ELSE YEAR(@today) END;

IF DAY(@today) = 1
BEGIN
    -- Full rebuild, every fiscal year. 16-38 minutes.
    -- Closed fiscal years never change, which is why this is monthly and not nightly.
    RAISERROR('Finance ledger: full rebuild (all fiscal years).', 0, 1) WITH NOWAIT;
    EXEC dbo.usp_RefreshFinanceLedgerSnapshotAll @Force = 0;
END
ELSE
BEGIN
    -- Current + prior fiscal year. 2-6 minutes.
    -- Daily is for RESILIENCE, not freshness: the sanity gates keep the previous
    -- snapshot when a build looks wrong, so a monthly-only cadence would let one
    -- bad run leave the figures stale for up to 31 days.
    DECLARE @fromYear varchar(10) = CONVERT(varchar(10), @currFY - 1);
    RAISERROR('Finance ledger: refreshing FY%s onward.', 0, 1, @fromYear) WITH NOWAIT;
    EXEC dbo.usp_RefreshFinanceLedgerSnapshotAll @FromYear = @fromYear, @Force = 0;
END
   -- =========================== end GUI STEP COMMAND ==========================
   =========================================================================== */


/* ===========================================================================
   APPENDIX D — optional: revoke EXECUTE from `finance`   [runbook Optional B]
   ---------------------------------------------------------------------------
   The app connects as `finance`, a read-only login. Under the old Laravel
   schedule it needed EXECUTE on a proc that truncates and rewrites the
   snapshot — a web-facing login with write power over the reporting data. Agent
   removes that need entirely.

   Cost: `php artisan ledger:refresh`, scripts\refresh-ledger.ps1 and
   manage-ledger.bat options 2-5 stop working by design. Manual refreshes move
   to SSMS. `ledger:status` is read-only and is unaffected.

   Do this only after the job has run unattended for a few days.

   -- USE FinanceAutomationSystem;
   -- REVOKE EXECUTE ON dbo.usp_RefreshFinanceLedgerSnapshot    FROM [finance];
   -- REVOKE EXECUTE ON dbo.usp_RefreshFinanceLedgerSnapshotAll FROM [finance];
   =========================================================================== */
