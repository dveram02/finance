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
# It is also the ONLY alerting path, because Database Mail is not configured on
# sqlapp\SQLEXPRESS - a failed Agent job writes to sysjobhistory and the Windows
# Application event log and nowhere a human looks. And a job that is DISABLED
# never fails, so it would send nothing even once mail is enabled. This task is
# not optional.
#
# The failure this exists to catch:
#   If the scheduler stops, NOTHING errors. No exception, no warning banner, no
#   failed request. Every page keeps loading fast and looking correct - the
#   figures just quietly stop moving, and the gap widens by a day every day.
#   Staleness therefore has to be asserted against the clock; it can never be
#   detected by waiting for something to break.
#
# Delegates the actual check to `php artisan ledger:status`, which reads
# dbo.FinanceLedgerRefresh through Laravel's configured connection. That keeps
# the SQL Server credentials in .env and out of this script.
#
# Windows Task Scheduler setup:
#   Program  : powershell.exe
#   Arguments: -NonInteractive -ExecutionPolicy Bypass -File "C:\Apache24\htdocs\production\finance\scripts\check-ledger-health.ps1"
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
$appPath           = "C:\Apache24\htdocs\production\finance"
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
        Write-Log "CRITICAL: Ledger snapshot is stale, aborted, or unreadable (exit $statusExit)."
        Send-Alert "SWRHA Finance - Ledger Snapshot Stale" @"
The finance ledger snapshot has failed its freshness check.

$($statusOutput -join "`r`n")

The application is still serving data, but the figures are out of date.

Check the SQL Agent job 'SWRHA Finance - Ledger Refresh' on sqlapp\SQLEXPRESS:
  - is the job enabled, and is the SQL Server Agent service running?
  - SELECT * FROM msdb.dbo.sysjobhistory for the failure reason
  - SELECT * FROM FinanceAutomationSystem.dbo.FinanceLedgerRefresh for Outcome/Message

An Outcome of 'ABORTED' means a sanity gate held the previous snapshot on
purpose - read the Message before forcing anything.
"@
    } else {
        Write-Log "OK: Ledger snapshot is fresh."
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
