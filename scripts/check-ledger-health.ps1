# ============================================================================
# SWRHA Finance - Ledger Health Check
# ============================================================================
# Run via Windows Task Scheduler every 30 minutes.
#
# This is the Finance equivalent of the Nexus "Queue Health Check" task, but it
# watches a DIFFERENT failure. Finance dispatches no queued jobs at all (no
# app\Jobs, no app\Notifications, no ShouldQueue), so there is no queue worker
# to monitor. What it has instead is a scheduled SQL Server snapshot that the
# whole application reads from.
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

# ── Is the scheduler task itself alive? ─────────────────────────────────────
# Checked independently of snapshot age, because it fails FIRST: the task can
# stop hours before the snapshot is old enough to trip the age threshold.
try {
    $schedulerTask = Get-ScheduledTask -TaskName "SWRHA Finance - Scheduler" -ErrorAction SilentlyContinue
    if (-not $schedulerTask) {
        Write-Log "CRITICAL: Scheduled task 'SWRHA Finance - Scheduler' does not exist."
        Send-Alert "SWRHA Finance - Scheduler Task Missing" "The 'SWRHA Finance - Scheduler' task is not registered. The ledger will go stale."
    } elseif ($schedulerTask.State -eq "Disabled") {
        Write-Log "CRITICAL: Scheduled task 'SWRHA Finance - Scheduler' is DISABLED."
        Send-Alert "SWRHA Finance - Scheduler Disabled" "The 'SWRHA Finance - Scheduler' task is disabled. The ledger will go stale."
    } else {
        $info = Get-ScheduledTaskInfo -TaskName "SWRHA Finance - Scheduler" -ErrorAction SilentlyContinue
        Write-Log "OK: Scheduler task state=$($schedulerTask.State), last run=$($info.LastRunTime), last result=$($info.LastTaskResult)"
    }
} catch {
    Write-Log "WARNING: Could not query the scheduler task: $($_.Exception.Message)"
}

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
Check that the 'SWRHA Finance - Scheduler' task is running, then run:
    php artisan ledger:refresh
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
