# ============================================================================
# SWRHA Finance - Ledger Health Check
# ============================================================================
# Run via Windows Task Scheduler every 30 minutes.
#
# THIS IS THE ONLY WINDOWS SCHEDULED TASK FINANCE REGISTERS. There is no
# scheduler task (the refresh is a SQL Server Agent job) and no queue worker
# (Finance dispatches nothing: no app\Jobs, no app\Notifications, no
# ShouldQueue). What it monitors is the SQL Server snapshot that the whole
# application reads from.
#
# DATABASE MAIL IS NOW CONFIGURED on sqlapp\SQLEXPRESS (sql\FinanceDatabaseMail.sql),
# so a job that RUNS AND FAILS now emails the Finance Admin operator. That covers
# a real gap - but it does NOT make this task redundant, and the reason is worth
# understanding before anyone decides to retire it:
#
#   Database Mail can only alert on a job that FIRES. It sends nothing when the
#   Agent service is stopped, when the job is disabled, or when the job has been
#   deleted - because in those cases nothing runs to send the mail. A DISABLED
#   job never fails, so it never emails, and the figures go stale in exactly the
#   same way.
#
#     failure                        Database Mail   this task
#     ---------------------------    -------------   ---------
#     a sanity gate aborts a step         YES           yes
#     step 2 fails, step 1 succeeded      YES           yes (drift)
#     SQL Agent service stopped           ** NO **      YES
#     job disabled                        ** NO **      YES
#     job deleted                         ** NO **      YES
#
# This task is the only monitor living in a DIFFERENT FAILURE DOMAIN from the
# thing it monitors - which is also why it is not a second Agent job on the DB
# server. A watchdog inside the process it watches cannot report that the
# process has died. The two-server topology is what makes this possible.
#
# Register it with scripts\register-health-check-task.ps1.
#
# The failure this exists to catch:
#   If the scheduler stops, NOTHING errors. No exception, no warning banner, no
#   failed request. Every page keeps loading fast and looking correct - the
#   figures just quietly stop moving, and the gap widens by a day every day.
#   Staleness therefore has to be asserted against the clock; it can never be
#   detected by waiting for something to break.
#
# PHASE 2 ADDED A SECOND, SUBTLER VERSION OF THE SAME FAILURE. The Agent job now
# has TWO steps: step 1 builds the ledger snapshot, step 2 builds the requisition
# detail snapshot. Agent steps cannot share a transaction, so step 1 can succeed
# while step 2 fails - the summary advances, the detail does not, and a user
# drilling from one into the other sees two figures that disagree.
#
# Nothing about that is visible in either table on its own: both look fresh, they
# are simply from different nights. `ledger:status` therefore also asserts that
# the two RefreshedAt values are from the SAME RUN, and exits non-zero when they
# drift. That assertion is the entire monitoring story for step 2 - this script
# needed no new logic, only a wider alert body.
#
# Delegates the actual check to `php artisan ledger:status`, which reads
# dbo.FinanceLedgerRefresh AND dbo.FinanceRequisitionRefresh through Laravel's
# configured connection. That keeps the SQL Server credentials in .env and out of
# this script.
#
# Windows Task Scheduler setup:
#   Program  : powershell.exe
#   Arguments: -NonInteractive -ExecutionPolicy Bypass -File "C:\Apache24\htdocs\production\finance-automation-system\scripts\check-ledger-health.ps1"
#   Trigger  : Daily, repeat every 30 minutes for a duration of 1 day
#   Run whether user is logged on or not
#   Stop task if it runs longer than: 5 minutes
# ============================================================================

param (
    # One missed nightly run plus slack. Do not set this below 24 - the refresh
    # only runs once a day, so anything tighter alerts on healthy snapshots.
    [int]$MaxAgeHours = 36
)

# Configuration
$appPath           = "C:\Apache24\htdocs\production\finance-automation-system"
$phpPath           = "C:\php\php.exe"        # UPDATE if PHP is elsewhere
$logFile           = "$appPath\storage\logs\ledger-health-check.log"
$alertEmail        = "admin@swrha.com"       # UPDATE for email alerts
$enableEmailAlerts = $false                  # Set to $true to enable email alerts

# Ensure log directory exists
$logDir = Split-Path -Parent $logFile
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry  = "$timestamp - $Message"
    Add-Content -Path $logFile -Value $logEntry
    Write-Host $logEntry
}

function Send-Alert {
    param([string]$Subject, [string]$Body)

    if (-not $enableEmailAlerts) { return }

    try {
        $smtpServer   = "smtp.example.com"    # UPDATE
        $smtpPort     = 587
        $smtpUsername = "alerts@swrha.com"    # UPDATE
        $smtpPassword = "your-password"       # UPDATE

        $message         = New-Object System.Net.Mail.MailMessage
        $message.From    = $smtpUsername
        $message.To.Add($alertEmail)
        $message.Subject = $Subject
        $message.Body    = $Body

        $smtp             = New-Object System.Net.Mail.SmtpClient($smtpServer, $smtpPort)
        $smtp.EnableSSL   = $true
        $smtp.Credentials = New-Object System.Net.NetworkCredential($smtpUsername, $smtpPassword)
        $smtp.Send($message)

        Write-Log "Alert email sent successfully"
    } catch {
        Write-Log "Failed to send alert email: $($_.Exception.Message)"
    }
}

if (-not (Test-Path $appPath)) {
    Write-Log "ERROR: Project root not found at '$appPath'. Aborting."
    exit 1
}

Set-Location $appPath

Write-Log "=== SWRHA Finance Ledger Health Check Started ==="

# Check Apache
$apacheRunning = Get-Process -Name "httpd" -ErrorAction SilentlyContinue
if (-not $apacheRunning) {
    Write-Log "WARNING: Apache HTTP Server is not running!"
    Send-Alert "SWRHA Finance - Apache Down" "Apache HTTP Server is not running on the server."
}

# ── NO SCHEDULER TASK CHECK — deliberate ────────────────────────────────────
# An earlier version checked Get-ScheduledTask "SWRHA Finance - Scheduler".
# That task no longer exists: the refresh moved to the SQL Server Agent job
# 'SWRHA Finance - Ledger Refresh' (sql\FinanceLedgerAgentJob.sql), because the
# instance is merely NAMED sqlapp\SQLEXPRESS while its edition is Standard.
#
# It is NOT replaced by an equivalent Agent-job check, for two reasons:
#
#   1. Reading msdb.dbo.sysjobs requires granting the `finance` login
#      SQLAgentReaderRole in msdb. This script deliberately holds no SQL
#      credentials of its own - it delegates to `php artisan`, which reads .env.
#      Querying the job directly would mean either widening a read-only login's
#      rights or putting credentials in this file.
#
#   2. It would not catch anything the freshness check below misses. A job that
#      is disabled, deleted, failing, or succeeding against a dead linked server
#      all produce the same observable symptom: RefreshedAt stops advancing.
#      Asserting staleness against the clock covers every cause at once.
#
# If you do want the job's own state surfaced here, grant the role:
#     USE msdb; CREATE USER [finance] FOR LOGIN [finance];
#     ALTER ROLE SQLAgentReaderRole ADD MEMBER [finance];
# and add the probe to App\Console\Commands\LedgerStatus so it stays behind
# artisan rather than being re-implemented here with a second set of credentials.

# ── Snapshot freshness (the real check) ─────────────────────────────────────
try {
    $statusOutput = & $phpPath artisan ledger:status --max-age-hours=$MaxAgeHours 2>&1
    $statusExit   = $LASTEXITCODE

    $statusOutput -split "`r?`n" | Where-Object { $_.Trim() -ne "" } | ForEach-Object { Write-Log "  $_" }

    if ($statusExit -ne 0) {
        Write-Log "CRITICAL: A finance snapshot is stale, aborted, out of step, or unreadable (exit $statusExit)."
        Send-Alert "SWRHA Finance - Snapshot Health Check Failed" @"
A finance snapshot has failed its freshness check.

$($statusOutput -join "`r`n")

The application is still serving data, but the figures are out of date.

READ THE MESSAGE ABOVE FIRST - it names which of the three failures this is.

  1. LEDGER STALE. The nightly job is not running at all.
  2. REQUISITION STALE, or the two snapshots are N MINUTES APART. Step 1
     succeeded and step 2 did not, so the detail pages now disagree with the
     summary they drill into. The job's own history will show step 2 failing
     while the job reports whatever step 1 did.
  3. ABORTED. A sanity gate held the previous snapshot ON PURPOSE. Read the
     Message before forcing anything - a RECONCILIATION FAILED message means
     the detail no longer ties to the summary, and --force does not bypass it.

Check the SQL Agent job 'SWRHA Finance - Ledger Refresh' on sqlapp\SQLEXPRESS:
  - is the job enabled, and is the SQL Server Agent service running?
  - does it still have BOTH steps, and is step 1's success action 'go to the
    next step'? If step 1 quits on success, step 2 never runs and the job
    reports success every night regardless:
      SELECT step_id, step_name, on_success_action FROM msdb.dbo.sysjobsteps s
      JOIN msdb.dbo.sysjobs j ON j.job_id = s.job_id
      WHERE j.name = 'SWRHA Finance - Ledger Refresh'
  - SELECT * FROM msdb.dbo.sysjobhistory for the failure reason
  - SELECT * FROM FinanceAutomationSystem.dbo.FinanceLedgerRefresh
  - SELECT TOP 5 * FROM FinanceAutomationSystem.dbo.FinanceRequisitionRefresh
    ORDER BY RunId DESC
"@
    } else {
        Write-Log "OK: Both snapshots are fresh and from the same run."
    }
} catch {
    Write-Log "ERROR: Could not run ledger:status: $($_.Exception.Message)"
    Send-Alert "SWRHA Finance - Health Check Failed" "check-ledger-health.ps1 could not run ledger:status: $($_.Exception.Message)"
}

# ── Disk space ──────────────────────────────────────────────────────────────
try {
    $storagePath = "$appPath\storage"
    $drive       = (Get-Item $storagePath).PSDrive.Name
    $driveInfo   = Get-PSDrive -Name $drive
    $freeSpaceGB = [math]::Round($driveInfo.Free / 1GB, 2)

    Write-Log "Available disk space on ${drive}: ${freeSpaceGB}GB"

    if ($freeSpaceGB -lt 5) {
        Write-Log "CRITICAL: Low disk space - only ${freeSpaceGB}GB remaining!"
        Send-Alert "SWRHA Finance - Low Disk Space" "Only ${freeSpaceGB}GB remaining on drive ${drive}:"
    }
} catch {
    Write-Log "WARNING: Could not check disk space: $($_.Exception.Message)"
}

# ── Log file sizes ──────────────────────────────────────────────────────────
try {
    $logFiles     = Get-ChildItem "$appPath\storage\logs" -Filter "*.log" -Recurse -ErrorAction SilentlyContinue
    $totalLogSize = ($logFiles | Measure-Object -Property Length -Sum).Sum / 1MB

    Write-Log "Total log file size: $([math]::Round($totalLogSize, 2))MB"

    if ($totalLogSize -gt 500) {
        Write-Log "WARNING: Log files are consuming $([math]::Round($totalLogSize, 2))MB. Consider log rotation."
    }
} catch {
    Write-Log "WARNING: Could not check log file sizes: $($_.Exception.Message)"
}

Write-Log "=== SWRHA Finance Ledger Health Check Completed ==="
Write-Log ""
