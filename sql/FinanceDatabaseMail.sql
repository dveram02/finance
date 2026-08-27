/* ===========================================================================
   FinanceDatabaseMail.sql   -   alerting for the Agent job  [DB server]
   ---------------------------------------------------------------------------
   Configures Database Mail on sqlapp\SQLEXPRESS and points the job
   `SWRHA Finance - Ledger Refresh` at an operator, so a failed refresh reaches
   a human instead of only sysjobhistory and the Windows event log.

   Supersedes APPENDIX B of sql/FinanceLedgerAgentJob.sql, which sketched this.

   ---------------------------------------------------------------------------
   *** READ THIS FIRST: WHAT THIS DOES AND DOES NOT COVER ***
   ---------------------------------------------------------------------------
   Database Mail alerts on a job that RUNS AND FAILS. It cannot alert on a job
   that NEVER RUNS, because nothing fires to send the mail:

     | Failure                        | Database Mail | Health check task |
     |--------------------------------|---------------|-------------------|
     | A sanity gate aborts a step    | YES           | yes               |
     | Step 2 fails, step 1 succeeded | YES           | yes (drift)       |
     | SQL Agent service is stopped   | ** NO **      | YES               |
     | The job is disabled            | ** NO **      | YES               |
     | The job is deleted             | ** NO **      | YES               |

   A DISABLED job never fails, so it never sends mail — and the data goes stale
   in exactly the same way. **This does not replace
   scripts/check-ledger-health.ps1 on the web server.** The two cover different
   halves, and the half this cannot see is the one that fails silently.

   ---------------------------------------------------------------------------
   BEFORE YOU RUN: fill in SECTION 1. Nothing else needs editing.
   ---------------------------------------------------------------------------
   Run as sysadmin on the DB server. Sections are meant to be run in order,
   reading the output of each.

   PREFER CLICKING?  ->  instructionsdatabasemail.md
   The full SSMS walkthrough: the Database Mail Configuration Wizard, the Agent
   Alert System page, the operator, and the job's Notifications page. It
   replaces SECTIONS 2, 3, 5 and 6 of this file. Same configuration either way.

   It does NOT replace three things, because the GUI has no equivalent of any
   of them — and each is a way for this to look configured while alerting
   nobody. Come back here for:

     SECTION 4b  the "sent" dialog is not proof of delivery, only of queueing;
     SECTION 6   sp_notify_operator — there is no GUI test for an operator, and
                 Agent's own lookup-and-send is a different path from the one
                 the Database Mail test exercises;
     SECTION 7   nothing in the GUI makes the job fail on purpose.

   Setup is a matter of taste. Verification is not.
   =========================================================================== */

SET NOCOUNT ON;
GO


/* ===========================================================================
   SECTION 1 — Your settings. EDIT THESE.
   ---------------------------------------------------------------------------
   Set them once here; later sections read them back from the objects they
   create, so this is the only place values are typed.

   AUTHENTICATION — pick ONE in section 3:
     (a) INTERNAL RELAY, no credentials. Most on-premises Exchange setups allow
         anonymous relay from known server IPs. Simplest, nothing to rotate.
     (b) AUTHENTICATED SMTP (Microsoft 365, or a relay requiring a login).
         Note M365 requires either SMTP AUTH enabled on the mailbox or a
         connector; a plain user password often will not work.

   If you do not know which applies, ask whoever runs mail BEFORE running this.
   Guessing produces a queued mail that never arrives and an empty error log.
   =========================================================================== */
DECLARE @MailServer   varchar(255) = 'smtp.swrha.co.tt';       -- <<< EDIT
DECLARE @MailPort     int          = 25;                        -- 25 relay, 587 authenticated
DECLARE @UseSSL       bit          = 0;                         -- 1 for 587/TLS
DECLARE @FromAddress  varchar(255) = 'sqlalerts@swrha.co.tt';   -- <<< EDIT (must be allowed to send)
DECLARE @ToAddress    varchar(255) = 'admin@swrha.co.tt';       -- <<< EDIT (who gets alerted)
DECLARE @OperatorName sysname      = N'Finance Admin';

SELECT @MailServer AS mail_server, @MailPort AS port, @UseSSL AS use_ssl,
       @FromAddress AS from_address, @ToAddress AS to_address;
GO


/* ===========================================================================
   SECTION 2 — Enable the Database Mail feature
   ---------------------------------------------------------------------------
   Off by default on this instance. No restart needed.
   =========================================================================== */
EXEC sp_configure 'show advanced options', 1;
RECONFIGURE;
EXEC sp_configure 'Database Mail XPs', 1;
RECONFIGURE;
GO

SELECT name, CONVERT(int, value_in_use) AS value_in_use
FROM sys.configurations WHERE name = 'Database Mail XPs';
-- value_in_use must be 1 before continuing.
GO


/* ===========================================================================
   SECTION 3 — Account and profile
   ---------------------------------------------------------------------------
   Idempotent: drops and recreates, so it is safe to re-run after a typo.
   Re-type your section 1 values here — this batch cannot see them.
   =========================================================================== */
DECLARE @MailServer  varchar(255) = 'smtp.swrha.co.tt';        -- <<< same as section 1
DECLARE @MailPort    int          = 25;                         -- <<< same as section 1
DECLARE @UseSSL      bit          = 0;                          -- <<< same as section 1
DECLARE @FromAddress varchar(255) = 'sqlalerts@swrha.co.tt';    -- <<< same as section 1

DECLARE @AccountName sysname = N'SWRHA Finance Alerts';
DECLARE @ProfileName sysname = N'SWRHA Finance Alerts';

/* ---- tear down any previous attempt ---------------------------------------- */
IF EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profileaccount pa
           JOIN msdb.dbo.sysmail_profile p ON p.profile_id = pa.profile_id
           WHERE p.name = @ProfileName)
    EXEC msdb.dbo.sysmail_delete_profileaccount_sp @profile_name = @ProfileName, @account_name = @AccountName;

IF EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profile WHERE name = @ProfileName)
    EXEC msdb.dbo.sysmail_delete_profile_sp @profile_name = @ProfileName;

IF EXISTS (SELECT 1 FROM msdb.dbo.sysmail_account WHERE name = @AccountName)
    EXEC msdb.dbo.sysmail_delete_account_sp @account_name = @AccountName;

/* ---- (a) INTERNAL RELAY, no credentials  — the default below ---------------- */
EXEC msdb.dbo.sysmail_add_account_sp
     @account_name    = @AccountName,
     @description     = N'Alerts from the SWRHA Finance ledger/requisition refresh job',
     @email_address   = @FromAddress,
     @display_name    = N'SWRHA Finance (SQL Server)',
     @mailserver_name = @MailServer,
     @port            = @MailPort,
     @enable_ssl      = @UseSSL;

/* ---- (b) AUTHENTICATED SMTP — use INSTEAD of (a) ---------------------------
   Comment out the block above, uncomment this, and supply the credentials.
   The password is stored encrypted in msdb; it is not readable back out.

EXEC msdb.dbo.sysmail_add_account_sp
     @account_name    = @AccountName,
     @description     = N'Alerts from the SWRHA Finance ledger/requisition refresh job',
     @email_address   = @FromAddress,
     @display_name    = N'SWRHA Finance (SQL Server)',
     @mailserver_name = @MailServer,
     @port            = @MailPort,
     @enable_ssl      = @UseSSL,
     @username        = 'sqlalerts@swrha.co.tt',
     @password        = '<put the password here, then DO NOT save this file>';
---------------------------------------------------------------------------- */

EXEC msdb.dbo.sysmail_add_profile_sp
     @profile_name = @ProfileName,
     @description  = N'SWRHA Finance alerting profile';

EXEC msdb.dbo.sysmail_add_profileaccount_sp
     @profile_name    = @ProfileName,
     @account_name    = @AccountName,
     @sequence_number = 1;

/* Public + default, so SQL Agent and any member of DatabaseMailUserRole can
   use it without naming a profile explicitly. */
EXEC msdb.dbo.sysmail_add_principalprofile_sp
     @profile_name = @ProfileName,
     @principal_name = N'public',
     @is_default = 1;
GO

SELECT p.name AS profile_, a.name AS account_, a.email_address,
       s.servername, s.port, s.enable_ssl,
       CASE WHEN s.credential_id IS NULL THEN 'anonymous relay' ELSE 'authenticated' END AS auth_
FROM msdb.dbo.sysmail_profile p
JOIN msdb.dbo.sysmail_profileaccount pa ON pa.profile_id = p.profile_id
JOIN msdb.dbo.sysmail_account a ON a.account_id = pa.account_id
JOIN msdb.dbo.sysmail_server s ON s.account_id = a.account_id;
GO


/* ===========================================================================
   SECTION 4 — Send a test mail, and actually verify it left
   ---------------------------------------------------------------------------
   sp_send_dbmail returns "Mail queued." immediately whether or not the SMTP
   server ever accepts it. **Queued is not sent.** Section 4b is the real check.
   =========================================================================== */
DECLARE @ToAddress varchar(255) = 'admin@swrha.co.tt';          -- <<< same as section 1

EXEC msdb.dbo.sp_send_dbmail
     @profile_name = N'SWRHA Finance Alerts',
     @recipients   = @ToAddress,
     @subject      = N'SWRHA Finance - Database Mail test',
     @body         = N'If you are reading this, Database Mail works on sqlapp\SQLEXPRESS. Sent by sql/FinanceDatabaseMail.sql section 4.';
GO

/* ---- 4b. Did it actually go? Wait ~30 seconds, then run this. -------------- */
SELECT TOP (10) mailitem_id, recipients, subject, sent_status, sent_date, last_mod_date
FROM msdb.dbo.sysmail_allitems ORDER BY mailitem_id DESC;

/* sent_status: sent = good. failed / unsent = read the error: */
SELECT TOP (20) l.log_date, l.event_type, l.description
FROM msdb.dbo.sysmail_event_log AS l ORDER BY l.log_id DESC;
GO

/* Common failures and what they mean:
     "Cannot send mails to mail server. (Failure sending mail.)"
         -> wrong server/port, or the firewall blocks outbound SMTP from the DB box.
     "The server rejected the sender address"
         -> @FromAddress is not permitted to send. Ask the mail team.
     "5.7.1 Client was not authenticated" / "Relay access denied"
         -> the relay wants credentials. Re-run section 3 using variant (b).
     sent_status stays 'unsent' with NO log rows
         -> the Database Mail external program is not starting. Check that
            DatabaseMail.exe exists in the instance BINN folder and that
            'Database Mail XPs' is 1.                                          */


/* ===========================================================================
   SECTION 5 — Point SQL Agent at the profile
   ---------------------------------------------------------------------------
   THIS IS THE STEP MOST OFTEN MISSED. Database Mail can work perfectly while
   Agent still sends nothing, because Agent has its own mail setting.

   *** AGENT MUST BE RESTARTED AFTER THIS. Alerting stays off until you do. ***

   GUI: Object Explorer > right-click SQL Server Agent > Properties >
        Alert System > tick "Enable mail profile",
        Mail system = Database Mail, Mail profile = SWRHA Finance Alerts > OK.
        Then right-click SQL Server Agent > Restart.

   T-SQL equivalent (writes the same registry values):
   =========================================================================== */
EXEC msdb.dbo.sp_set_sqlagent_properties
     @email_save_in_sent_folder = 1;
GO

EXEC master.dbo.xp_instance_regwrite
     N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent',
     N'UseDatabaseMail', N'REG_DWORD', 1;

EXEC master.dbo.xp_instance_regwrite
     N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent',
     N'DatabaseMailProfile', N'REG_SZ', N'SWRHA Finance Alerts';
GO

/* Read it back. Both values must be as written above. */
DECLARE @UseDbMail int, @Profile nvarchar(128);
EXEC master.dbo.xp_instance_regread
     N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent',
     N'UseDatabaseMail', @UseDbMail OUTPUT;
EXEC master.dbo.xp_instance_regread
     N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent',
     N'DatabaseMailProfile', @Profile OUTPUT;
SELECT @UseDbMail AS use_database_mail, @Profile AS agent_mail_profile;
GO

/* >>> RESTART SQL SERVER AGENT NOW. <<<
       SSMS: right-click SQL Server Agent > Restart.
       Or:   net stop SQLAgent$SQLEXPRESS && net start SQLAgent$SQLEXPRESS   */


/* ===========================================================================
   SECTION 6 — Operator, and attach it to the job
   =========================================================================== */
DECLARE @ToAddress    varchar(255) = 'admin@swrha.co.tt';       -- <<< same as section 1
DECLARE @OperatorName sysname      = N'Finance Admin';

IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysoperators WHERE name = @OperatorName)
    EXEC msdb.dbo.sp_add_operator
         @name = @OperatorName, @enabled = 1, @email_address = @ToAddress;
ELSE
    EXEC msdb.dbo.sp_update_operator
         @name = @OperatorName, @enabled = 1, @email_address = @ToAddress;

/* notify_level_email = 2 -> on failure only.
   Job-level, so it covers BOTH steps: step 1's on_fail_action = 2 and step 2's
   both quit the job reporting failure, which is what triggers this. */
EXEC msdb.dbo.sp_update_job
     @job_name = N'SWRHA Finance - Ledger Refresh',
     @notify_level_email         = 2,
     @notify_email_operator_name = @OperatorName,
     @notify_level_eventlog      = 2;   -- keep the event-log entry as well
GO

/* Verify the job is wired up. */
SELECT j.name AS job_, j.enabled, j.notify_level_email, o.name AS operator_, o.email_address
FROM msdb.dbo.sysjobs j
LEFT JOIN msdb.dbo.sysoperators o ON o.id = j.notify_email_operator_id
WHERE j.name = N'SWRHA Finance - Ledger Refresh';
GO

/* Test the OPERATOR path specifically — this proves Agent's mail works, which
   is a different code path from section 4's sp_send_dbmail. Run it AFTER the
   Agent restart. */
EXEC msdb.dbo.sp_notify_operator
     @name = N'Finance Admin',
     @subject = N'SWRHA Finance - Agent operator test',
     @body    = N'Sent via sp_notify_operator. If this arrives, SQL Agent alerting is live.';
GO


/* ===========================================================================
   SECTION 7 — End-to-end proof: make the job actually fail once
   ---------------------------------------------------------------------------
   OPTIONAL BUT RECOMMENDED. Everything above can pass while the job still
   emails nobody. This is the only test that proves the whole chain.

   It adds a temporary third step that always fails, runs the job, and then
   removes it. The real steps still run first and succeed normally, so the
   snapshots are refreshed as usual — only the job OUTCOME is failed.

   *** REMEMBER TO RUN 7c. *** A left-behind failing step means the job reports
   failure every night forever.
   =========================================================================== */

-- 7a. Add the deliberate failure
-- EXEC msdb.dbo.sp_add_jobstep
--      @job_name = N'SWRHA Finance - Ledger Refresh',
--      @step_name = N'ZZ TEMP alert test - DELETE ME',
--      @subsystem = N'TSQL', @database_name = N'FinanceAutomationSystem',
--      @on_success_action = 2, @on_fail_action = 2, @retry_attempts = 0,
--      @command = N'THROW 51999, ''Deliberate failure to test alerting. Remove this step.'', 1;';
-- GO
-- -- point the previous last step at it
-- EXEC msdb.dbo.sp_update_jobstep
--      @job_name = N'SWRHA Finance - Ledger Refresh', @step_id = 2, @on_success_action = 3;
-- GO

-- 7b. Run it, wait, and confirm an email arrives
-- EXEC msdb.dbo.sp_start_job @job_name = N'SWRHA Finance - Ledger Refresh';
-- GO

-- 7c. *** CLEAN UP — DO NOT SKIP ***
-- EXEC msdb.dbo.sp_delete_jobstep
--      @job_name = N'SWRHA Finance - Ledger Refresh', @step_id = 3;
-- EXEC msdb.dbo.sp_update_jobstep
--      @job_name = N'SWRHA Finance - Ledger Refresh', @step_id = 2, @on_success_action = 1;
-- GO
-- -- Confirm the job is back to exactly two steps, 3 then 1:
-- SELECT s.step_id, s.step_name, s.on_success_action, s.on_fail_action
-- FROM msdb.dbo.sysjobs j JOIN msdb.dbo.sysjobsteps s ON s.job_id = j.job_id
-- WHERE j.name = N'SWRHA Finance - Ledger Refresh' ORDER BY s.step_id;
-- GO


/* ===========================================================================
   SECTION 8 — Rollback
   =========================================================================== */
-- EXEC msdb.dbo.sp_update_job @job_name = N'SWRHA Finance - Ledger Refresh',
--      @notify_level_email = 0, @notify_email_operator_name = N'';
-- EXEC msdb.dbo.sp_delete_operator @name = N'Finance Admin';
-- EXEC msdb.dbo.sysmail_delete_profileaccount_sp
--      @profile_name = N'SWRHA Finance Alerts', @account_name = N'SWRHA Finance Alerts';
-- EXEC msdb.dbo.sysmail_delete_profile_sp @profile_name = N'SWRHA Finance Alerts';
-- EXEC msdb.dbo.sysmail_delete_account_sp @account_name = N'SWRHA Finance Alerts';
-- EXEC master.dbo.xp_instance_regwrite
--      N'HKEY_LOCAL_MACHINE', N'SOFTWARE\Microsoft\MSSQLServer\SQLServerAgent',
--      N'UseDatabaseMail', N'REG_DWORD', 0;
-- GO
-- -- then restart SQL Server Agent


/* ===========================================================================
   AFTER THIS: the remaining gap, stated plainly
   ---------------------------------------------------------------------------
   You now get email when the job RUNS AND FAILS. You still get nothing when it
   does not run at all — Agent stopped, job disabled, job deleted. That is the
   failure that produces no record anywhere, and only
   scripts/check-ledger-health.ps1 on the WEB server catches it, because it is
   the only monitor in a different failure domain from the thing it monitors.

   Register it with scripts/register-health-check-task.ps1.
   =========================================================================== */
