# =============================================================================
# run-scheduler.ps1
#
# Runs Laravel's task scheduler (php artisan schedule:run).
# This is the single entry point for all scheduled commands:
#
#   02:00 daily    ledger:refresh          (current + prior fiscal year, ~2-4 min)
#   03:00 Sundays  ledger:refresh --all    (every fiscal year, 20+ min)
#
# Must be triggered every minute by Windows Task Scheduler.
# Laravel handles which commands are due at any given minute.
#
# Windows Task Scheduler setup:
#   Program  : powershell.exe
#   Arguments: -NonInteractive -ExecutionPolicy Bypass -File "C:\Apache24\htdocs\production\finance\scripts\run-scheduler.ps1"
#   Trigger  : Daily, repeat every 1 minute for a duration of 1 day
#   Run whether user is logged on or not
#   Run with highest privileges: NO (least privilege)
#   Stop task if it runs longer than: 4 HOURS   <-- see warning below
#
# *** DIFFERENT FROM THE NEXUS SCHEDULER TASK ***
# The Nexus equivalent uses "Stop task if it runs longer than: 5 minutes".
# DO NOT copy that here. schedule:run executes due commands SYNCHRONOUSLY, and
# the Sunday 03:00 full rebuild runs for 20+ minutes (longer on a busy server).
# A 5-minute limit would kill it mid-rebuild, every week. Combined with
# "Do not start a new instance", the per-minute triggers during a long rebuild
# are simply skipped, which is the desired behaviour.
#
# A killed rebuild is SAFE - the snapshot swap is transactional and the previous
# data survives - but it never completes, so the ledger silently stops advancing.
# =============================================================================

$APP_ROOT = "C:\Apache24\htdocs\production\finance"
$PHP_BIN  = "php"
$LogDir   = "$APP_ROOT\storage\logs\scheduler"
$LogFile  = "$LogDir\schedule-$(Get-Date -Format 'yyyy-MM-dd').log"

# Ensure log directory exists
if (-not (Test-Path $LogDir)) {
    New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
}

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}

# Verify PHP is available
if (-not (Get-Command $PHP_BIN -ErrorAction SilentlyContinue)) {
    Write-Log "ERROR: php not found in PATH. Aborting."
    exit 1
}

# Verify project root exists
if (-not (Test-Path $APP_ROOT)) {
    Write-Log "ERROR: Project root not found at '$APP_ROOT'. Aborting."
    exit 1
}

Set-Location $APP_ROOT

$output = & $PHP_BIN artisan schedule:run 2>&1
$exitCode = $LASTEXITCODE

# Only log when there is meaningful output (i.e. a command actually ran)
$filteredOutput = $output | Where-Object { $_ -and $_.Trim() -ne "" }

if ($filteredOutput) {
    foreach ($line in $filteredOutput) {
        Write-Log $line
    }
    if ($exitCode -ne 0) {
        Write-Log "WARNING: schedule:run exited with code $exitCode"
    }
}

exit $exitCode
