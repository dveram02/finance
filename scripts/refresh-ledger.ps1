# ============================================================
# refresh-ledger.ps1
#
# Rebuilds the finance ledger snapshot on SQL Server.
#
# NOTE: This script is for manual or one-off runs only.
# The scheduler (run-scheduler.ps1) already runs this automatically:
#   02:00 daily    ledger:refresh          (current + prior fiscal year)
#   03:00 Sundays  ledger:refresh --all    (every fiscal year)
# Under normal operation you never need to run this by hand.
#
# Reach for it when:
#   - doing the initial production build (instructions.md step 4)
#   - a scheduled run ABORTED on a sanity gate and you have confirmed the
#     movement is genuine (then pass -Force)
#   - the GL was reloaded out of band and you want the figures now
#
# Timing: roughly 90-110 seconds PER FISCAL YEAR on the reference server.
# -All covers 13 years, so expect 20+ minutes. Run it in a window where a
# long SQL Server scan will not disturb anything else.
#
# Usage (manual):
#   powershell.exe -NonInteractive -ExecutionPolicy Bypass -File "C:\Apache24\htdocs\production\finance\scripts\refresh-ledger.ps1"
#   ... -Year 2026
#   ... -All
#   ... -Year 2026 -Force
# ============================================================

param (
    # Specific fiscal year, e.g. 2026. Omit for current + prior fiscal year.
    [string]$Year,

    # Rebuild every fiscal year present in the source (~20+ minutes).
    [switch]$All,

    # Bypass the MOVEMENT sanity gates (row-count drop, money movement).
    # Never bypasses the zero-row gate. Use only after confirming a large
    # change is genuine - a new FY opening, or a bulk reallocation.
    [switch]$Force
)

$ProjectRoot = "C:\Apache24\htdocs\production\finance"
$LogDir      = "$ProjectRoot\storage\logs\scheduler"
$LogFile     = "$LogDir\refresh-ledger-$(Get-Date -Format 'yyyy-MM-dd').log"

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

Write-Log "=== Starting finance ledger refresh ==="

# Verify PHP is available
if (-not (Get-Command php -ErrorAction SilentlyContinue)) {
    Write-Log "ERROR: php not found in PATH. Aborting."
    exit 1
}

# Verify project root exists
if (-not (Test-Path $ProjectRoot)) {
    Write-Log "ERROR: Project root not found at '$ProjectRoot'. Aborting."
    exit 1
}

if ($All -and $Year) {
    Write-Log "ERROR: -All and -Year are mutually exclusive. Aborting."
    exit 1
}

Set-Location $ProjectRoot

$ArtisanArgs = @("artisan", "ledger:refresh")

if ($All) {
    $ArtisanArgs += "--all"
    Write-Log "Mode: ALL fiscal years (expect 20+ minutes)"
} elseif ($Year) {
    $ArtisanArgs += "--year=$Year"
    Write-Log "Mode: fiscal year $Year"
} else {
    Write-Log "Mode: current + prior fiscal year"
}

if ($Force) {
    $ArtisanArgs += "--force"
    Write-Log "Force: ON - movement sanity gates bypassed (zero-row gate still applies)"
}

$startedAt = Get-Date

# Run the command and capture output
$output = & php @ArtisanArgs 2>&1
$exitCode = $LASTEXITCODE

foreach ($line in $output) {
    Write-Log $line
}

$elapsed = [math]::Round(((Get-Date) - $startedAt).TotalMinutes, 1)

if ($exitCode -eq 0) {
    Write-Log "=== Completed successfully in $elapsed minutes ==="
} else {
    # A failed refresh is not a data-loss event: the swap is transactional and
    # the previous snapshot is retained. The app keeps serving the last good data.
    Write-Log "=== FAILED with exit code $exitCode after $elapsed minutes ==="
    Write-Log "The previous snapshot has been retained. Check dbo.FinanceLedgerRefresh for the reason."
}

exit $exitCode
