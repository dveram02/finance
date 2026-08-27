# ============================================================================
# SWRHA Finance - register the ledger health check scheduled task   [WEB box]
# ============================================================================
# Creates the ONE Windows scheduled task Finance registers:
#   "SWRHA Finance - Ledger Health Check"  ->  check-ledger-health.ps1
#   every 30 minutes, which runs `php artisan ledger:status`.
#
# WHY THIS EXISTS, given Database Mail is now configured on the DB server:
#   Database Mail alerts on a job that RUNS AND FAILS. It cannot alert on a job
#   that NEVER RUNS - a stopped Agent service, a disabled job, a deleted job -
#   because nothing fires to send the mail. A disabled job never fails, so it
#   never emails, and the figures go stale exactly the same way.
#
#   This task is the only monitor that lives in a DIFFERENT FAILURE DOMAIN from
#   the thing it monitors. That is the whole reason it is on the web server and
#   not a second Agent job on the DB server: a watchdog inside the process it
#   watches cannot report that the process has died.
#
# Run this ONCE, from an elevated PowerShell prompt on the WEB server.
# Re-running is safe: it unregisters and recreates the task.
#
#   .\register-health-check-task.ps1
#   .\register-health-check-task.ps1 -RunAsUser "FinanceSvc"
#   .\register-health-check-task.ps1 -WhatIf          # show, change nothing
# ============================================================================

[CmdletBinding(SupportsShouldProcess = $true)]
param (
    # The application root on this server.
    [string]$AppPath = "C:\Apache24\htdocs\production\finance-automation-system",

    # PHP CLI.
    [string]$PhpPath = "C:\php\php.exe",

    # Account to run as. Leave blank to run as SYSTEM.
    #
    # SYSTEM works and needs no password, but it is broad. A dedicated local
    # account (instructionsforschedule.md step 8) is preferable: it needs no
    # rights on the DB server at all, because the check shells out to
    # `php artisan`, which connects as the `finance` SQL login from .env. The
    # Windows identity never crosses the network.
    [string]$RunAsUser = "",

    [string]$TaskName = "SWRHA Finance - Ledger Health Check",

    # Minutes between checks. 30 matches the documented cadence.
    [int]$IntervalMinutes = 30,

    # Passed through to check-ledger-health.ps1. Do not go below 24: the refresh
    # runs once a day, so anything tighter alerts on healthy snapshots.
    [int]$MaxAgeHours = 36
)

$ErrorActionPreference = "Stop"

function Write-Step { param([string]$m) Write-Host "  $m" }

Write-Host ""
Write-Host "SWRHA Finance - health check task registration" -ForegroundColor Cyan
Write-Host "=============================================="

# ---- Preflight -------------------------------------------------------------
# Every one of these has been a real failure at least once. Checking them here
# turns a silent 30-minute-loop no-op into an error you see now.

$script = Join-Path $AppPath "scripts\check-ledger-health.ps1"

if (-not (Test-Path $AppPath)) {
    throw "Application root not found: '$AppPath'. Pass -AppPath with the correct location."
}
Write-Step "App root      : $AppPath"

if (-not (Test-Path $script)) {
    throw "Health check script not found: '$script'. Is this deployment up to date?"
}
Write-Step "Health script : $script"

if (-not (Test-Path $PhpPath)) {
    throw "PHP not found: '$PhpPath'. Pass -PhpPath with the correct location."
}
Write-Step "PHP           : $PhpPath"

# The script hardcodes its own $appPath. If someone moved the app without
# updating it, the task would run and abort at "Project root not found" every
# 30 minutes - which looks identical to healthy silence.
$scriptAppPath = Select-String -Path $script -Pattern '^\s*\$appPath\s*=\s*"([^"]+)"' |
                 Select-Object -First 1
if ($scriptAppPath) {
    $declared = $scriptAppPath.Matches[0].Groups[1].Value
    if ($declared -ne $AppPath) {
        Write-Host ""
        Write-Warning "check-ledger-health.ps1 has `$appPath = '$declared'"
        Write-Warning "but this task will point at  '$AppPath'."
        Write-Warning "The script aborts on a path it cannot find. Fix line `$appPath in the script first."
        throw "Path mismatch - refusing to register a task that would abort every run."
    }
    Write-Step "Path match    : ok"
}

# ---- Prove the check actually works BEFORE scheduling it -------------------
# Scheduling something that has never run once is how a failure first becomes
# visible to nobody.
Write-Host ""
Write-Host "Running ledger:status once to prove it works..." -ForegroundColor Cyan
Push-Location $AppPath
try {
    $out  = & $PhpPath artisan ledger:status --max-age-hours=$MaxAgeHours 2>&1
    $code = $LASTEXITCODE
} finally {
    Pop-Location
}
$out | ForEach-Object { Write-Host "    $_" }

if ($code -ne 0) {
    Write-Host ""
    Write-Warning "ledger:status exited $code - a snapshot is stale, aborted, or out of step."
    Write-Warning "The task is still worth registering (that is what it is for), but resolve"
    Write-Warning "the underlying problem too, or the first alert will be about this."
} else {
    Write-Step "ledger:status : exit 0"
}

# ---- Build the task --------------------------------------------------------
$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NonInteractive -NoProfile -ExecutionPolicy Bypass -File `"$script`" -MaxAgeHours $MaxAgeHours" `
    -WorkingDirectory $AppPath

# Repeat-forever triggers are awkward in this cmdlet set: -Daily has no
# repetition parameters, so the Repetition block is borrowed from a -Once
# trigger. This is the standard workaround, not a hack around something safer.
$trigger = New-ScheduledTaskTrigger -Daily -At (Get-Date "00:00")
$repeat  = New-ScheduledTaskTrigger -Once -At (Get-Date "00:00") `
             -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes) `
             -RepetitionDuration (New-TimeSpan -Days 1)
$trigger.Repetition = $repeat.Repetition

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

$description = "Monitors finance ledger AND requisition snapshot freshness, and asserts both " +
               "come from the same Agent job run. Catches the failure Database Mail cannot: " +
               "a refresh job that never runs. See scripts/check-ledger-health.ps1."

if ([string]::IsNullOrWhiteSpace($RunAsUser)) {
    Write-Host ""
    Write-Step "Run as        : SYSTEM"
    $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Limited
    $cred = $null
} else {
    Write-Host ""
    Write-Step "Run as        : $RunAsUser"
    Write-Host ""
    Write-Host "  '$RunAsUser' needs:" -ForegroundColor Yellow
    Write-Host "    - 'Log on as a batch job'  (secpol.msc > Local Policies > User Rights Assignment)"
    Write-Host "    - modify on $AppPath\storage  and  $AppPath\bootstrap\cache"
    Write-Host "    - read on $AppPath\.env"
    Write-Host ""
    $cred = Get-Credential -UserName $RunAsUser -Message "Password for $RunAsUser (the scheduled task)"
    $principal = $null
}

# ---- Register --------------------------------------------------------------
if ($PSCmdlet.ShouldProcess($TaskName, "Register scheduled task")) {

    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Write-Step "Removing the existing task first..."
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }

    if ($null -ne $cred) {
        Register-ScheduledTask -TaskName $TaskName -Description $description `
            -Action $action -Trigger $trigger -Settings $settings `
            -User $cred.UserName `
            -Password $cred.GetNetworkCredential().Password `
            -RunLevel Limited | Out-Null
    } else {
        Register-ScheduledTask -TaskName $TaskName -Description $description `
            -Action $action -Trigger $trigger -Settings $settings `
            -Principal $principal | Out-Null
    }

    Write-Host ""
    Write-Host "Registered." -ForegroundColor Green

    # ---- Run it once now and read the result -------------------------------
    Write-Host "Starting it once to confirm it runs end to end..." -ForegroundColor Cyan
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 25

    $info = Get-ScheduledTaskInfo -TaskName $TaskName
    Write-Host ""
    Write-Host ("  Last run    : {0}" -f $info.LastRunTime)
    Write-Host ("  Last result : {0}" -f $info.LastTaskResult)

    if ($info.LastTaskResult -eq 0) {
        Write-Host "  OK - the task ran and the health check passed." -ForegroundColor Green
    } elseif ($info.LastTaskResult -eq 267009) {
        Write-Host "  Still running; re-check with Get-ScheduledTaskInfo in a moment." -ForegroundColor Yellow
    } else {
        Write-Host "  Non-zero result. Read the log below before assuming it is broken -" -ForegroundColor Yellow
        Write-Host "  a stale snapshot is a CORRECT non-zero result." -ForegroundColor Yellow
    }

    $log = Join-Path $AppPath "storage\logs\ledger-health-check.log"
    if (Test-Path $log) {
        Write-Host ""
        Write-Host "  Tail of $log :"
        Get-Content $log -Tail 15 | ForEach-Object { Write-Host "    $_" }
    } else {
        Write-Host ""
        Write-Warning "  No log at $log - the script may not have started. Check the task history."
    }
}

Write-Host ""
Write-Host "Verify or manage later:" -ForegroundColor Cyan
Write-Host "  Get-ScheduledTask     -TaskName `"$TaskName`""
Write-Host "  Get-ScheduledTaskInfo -TaskName `"$TaskName`""
Write-Host "  Start-ScheduledTask   -TaskName `"$TaskName`"     # run on demand"
Write-Host "  Unregister-ScheduledTask -TaskName `"$TaskName`" -Confirm:`$false"
Write-Host ""
