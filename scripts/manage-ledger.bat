@echo off
REM ============================================================================
REM SWRHA Finance - Ledger Management
REM ============================================================================
REM Interactive menu for manual ledger operations.
REM Run this directly - do NOT add to Task Scheduler.
REM
REM Finance runs NO queue worker (it dispatches no queued jobs), so unlike the
REM Nexus equivalent there is nothing here to start or stop.
REM
REM It also runs no scheduler task. The scheduled refresh is the SQL Server
REM Agent job 'SWRHA Finance - Ledger Refresh' (sql\FinanceLedgerAgentJob.sql),
REM which is managed in SSMS, not from here - this menu has no SQL credentials
REM of its own and the app's `finance` login cannot read or start Agent jobs.
REM The one Windows task Finance registers is the health check, options 6-7.
REM ============================================================================

echo ========================================
echo  SWRHA Finance - Ledger Management
echo ========================================
echo.
echo  Scheduled refresh: SQL Agent job "SWRHA Finance - Ledger Refresh"
echo  Manage it in SSMS - Object Explorer, SQL Server Agent, Jobs.
echo.
echo 1. Check ledger freshness (status)
echo 2. Refresh current + prior fiscal year   (~2-6 min)
echo 3. Refresh a specific fiscal year
echo 4. Refresh ALL fiscal years              (16-38 min)
echo 5. Force refresh a year (bypass movement gates)
echo 6. Health check task status
echo 7. Run health check task now
echo 8. View health check log
echo 9. View manual refresh log (today)
echo 10. Clear filter caches
echo 11. Exit
echo.
set /p choice="Enter your choice (1-11): "

cd /d "C:\Apache24\htdocs\production\finance"

if "%choice%"=="1" goto status
if "%choice%"=="2" goto refresh_recent
if "%choice%"=="3" goto refresh_year
if "%choice%"=="4" goto refresh_all
if "%choice%"=="5" goto refresh_force
if "%choice%"=="6" goto task_status
if "%choice%"=="7" goto task_run
if "%choice%"=="8" goto log_health
if "%choice%"=="9" goto log_refresh
if "%choice%"=="10" goto clear_cache
if "%choice%"=="11" goto end

REM Options 2-5 run the refresh through `php artisan`, i.e. as the `finance`
REM login. If you take the optional hardening step of revoking EXECUTE on the
REM refresh procs from that login, they stop working by design - run the Agent
REM job or the proc from SSMS instead. Option 1 is read-only and is unaffected.

:status
php artisan ledger:status
pause
goto end

:refresh_recent
php artisan ledger:refresh
pause
goto end

:refresh_year
set /p fy="Fiscal year (e.g. 2026): "
php artisan ledger:refresh --year=%fy%
pause
goto end

:refresh_all
echo This rebuilds every fiscal year and takes 16-38 minutes.
echo The Agent job already does this on the 1st of each month.
set /p confirm="Continue? (Y/N): "
if /i not "%confirm%"=="Y" goto end
php artisan ledger:refresh --all
pause
goto end

:refresh_force
echo WARNING: --force bypasses the movement sanity gates.
echo Only use this after confirming a large change is genuine
echo (a new fiscal year opening, or a bulk reallocation).
echo The zero-row gate still applies.
set /p fy="Fiscal year (e.g. 2026): "
set /p confirm="Force refresh FY%fy%? (Y/N): "
if /i not "%confirm%"=="Y" goto end
php artisan ledger:refresh --year=%fy% --force
pause
goto end

:task_status
schtasks /Query /TN "SWRHA Finance - Ledger Health Check" /FO LIST /V
pause
goto end

:task_run
schtasks /Run /TN "SWRHA Finance - Ledger Health Check"
echo Health check task triggered. View the log with option 8.
pause
goto end

:log_health
start notepad "storage\logs\ledger-health-check.log"
goto end

:log_refresh
REM Written by refresh-ledger.ps1 for MANUAL runs only. The Agent job's history
REM is in SQL Server: msdb.dbo.sysjobhistory, and dbo.FinanceLedgerRefresh.
for /f "tokens=1-3 delims=/ " %%a in ('date /t') do set today=%%c-%%a-%%b
start notepad "storage\logs\ledger\refresh-ledger-%today%.log"
goto end

:clear_cache
REM The filter caches live on the dedicated `file` store.
REM `php artisan cache:clear` alone will NOT touch them.
php artisan cache:clear file
echo Filter caches cleared.
pause
goto end

:end
