@echo off
REM ============================================================================
REM SWRHA Finance - Ledger Management
REM ============================================================================
REM Interactive menu for manual ledger operations.
REM Run this directly - do NOT add to Task Scheduler.
REM
REM Finance runs NO queue worker (it dispatches no queued jobs), so unlike the
REM Nexus equivalent there is nothing here to start or stop. What it manages
REM instead is the snapshot the whole application reads from.
REM ============================================================================

echo ========================================
echo  SWRHA Finance - Ledger Management
echo ========================================
echo.
echo 1. Check ledger freshness (status)
echo 2. Refresh current + prior fiscal year   (~2-4 min)
echo 3. Refresh a specific fiscal year
echo 4. Refresh ALL fiscal years              (20+ min)
echo 5. Force refresh a year (bypass movement gates)
echo 6. Scheduler task status
echo 7. Run scheduler task now
echo 8. View scheduler log (today)
echo 9. View health check log
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
if "%choice%"=="8" goto log_scheduler
if "%choice%"=="9" goto log_health
if "%choice%"=="10" goto clear_cache
if "%choice%"=="11" goto end

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
echo This rebuilds every fiscal year and takes 20+ minutes.
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
schtasks /Query /TN "SWRHA Finance - Scheduler" /FO LIST /V
pause
goto end

:task_run
schtasks /Run /TN "SWRHA Finance - Scheduler"
echo Scheduler task triggered.
pause
goto end

:log_scheduler
for /f "tokens=1-3 delims=/ " %%a in ('date /t') do set today=%%c-%%a-%%b
start notepad "storage\logs\scheduler\schedule-%today%.log"
goto end

:log_health
start notepad "storage\logs\ledger-health-check.log"
goto end

:clear_cache
REM The filter caches live on the dedicated `file` store.
REM `php artisan cache:clear` alone will NOT touch them.
php artisan cache:clear file
echo Filter caches cleared.
pause
goto end

:end
