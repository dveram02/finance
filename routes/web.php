<?php

use App\Http\Controllers\Auth\AuthenticatedSessionController;
use App\Http\Controllers\BudgetAllocationController;
use App\Http\Controllers\DashboardController;
use App\Http\Controllers\EncumberedDetailsController;
use App\Http\Controllers\MonthlyExpenditureController;
use App\Http\Controllers\ProfileController;
use App\Http\Controllers\RoutingDetailsController;
use App\Http\Controllers\VarianceController;
use Illuminate\Support\Facades\Route;
use Inertia\Inertia;

Route::get('/', fn () => redirect()->route('dashboard'));

// Guest routes
Route::middleware('guest')->group(function () {
    Route::get('/login', [AuthenticatedSessionController::class, 'create'])->name('login');
    Route::post('/login', [AuthenticatedSessionController::class, 'store'])
        ->middleware('throttle:login')
        ->name('login.store');
});

// Authenticated routes
Route::middleware(['auth', 'active.user'])->group(function () {
    Route::get('/dashboard', [DashboardController::class,        'index'])->name('dashboard');
    Route::get('/profile', [ProfileController::class,           'view'])->name('profile.view');
    Route::get('/budget-allocations', [BudgetAllocationController::class,  'index'])->name('budget-allocations.index');
    // Account x fiscal-month grid from dbo.vw_FinanceLedger. It carries the name
    // and the URL of the retired per-period page that read dbo.MonthlyExpenditure;
    // that page is gone, and its URL is NOT redirected from its old one.
    Route::get('/monthly-expenditure', [MonthlyExpenditureController::class, 'index'])->name('monthly-expenditure.index');
    Route::get('/variance', [VarianceController::class, 'index'])->name('variance.index');

    // Requisition-line drill-downs behind the ledger's Approved and Routing
    // columns (Phase 3). Same access rule as every other page — the department
    // mapping is inherited through vw_WebAppUserAccess, and there are no roles.
    Route::get('/encumbered-details', [EncumberedDetailsController::class, 'index'])->name('encumbered-details.index');
    Route::get('/routing-details', [RoutingDetailsController::class,  'index'])->name('routing-details.index');

    // CSV exports. Each streams the WHOLE filtered set for the active fiscal
    // year — `page` is presentation state and is ignored. GET, because an
    // export is read-only and its scope is already expressed in the query
    // string; the links are plain browser navigations, never Inertia visits.
    //
    // Deliberately NOT throttled: a bare 429 is the one response that would
    // bypass the redirect-with-warning error mode every export uses. If
    // throttling is ever needed, add a NAMED limiter whose response() returns
    // that same redirect. There is no export route for the retired
    // /department-expenditure or /allocation-line-expenditure URLs.
    //
    // The two requisition exports take ?fy as an OPTIONAL parameter (2026-10-01):
    // absent means every ELIGIBLE fiscal year, and the filename then carries no
    // fy segment. They are also the only two exports that can be refused for
    // SCOPE SIZE rather than a stale filter — above the row ceiling they
    // redirect with a warning rather than streaming a truncated file. See
    // routingupdate.md 6.6. The other four exports are unchanged and
    // single-year.
    Route::get('/budget-allocations/export', [BudgetAllocationController::class,  'export'])->name('budget-allocations.export');
    Route::get('/monthly-expenditure/export', [MonthlyExpenditureController::class, 'export'])->name('monthly-expenditure.export');
    Route::get('/variance/export', [VarianceController::class, 'export'])->name('variance.export');
    Route::get('/encumbered-details/export', [EncumberedDetailsController::class, 'export'])->name('encumbered-details.export');
    Route::get('/routing-details/export', [RoutingDetailsController::class,  'export'])->name('routing-details.export');
    Route::get('/dashboard/export', [DashboardController::class, 'export'])->name('dashboard.export');
});

// Logout
Route::post('/logout', [AuthenticatedSessionController::class, 'destroy'])
    ->middleware('auth')
    ->name('logout');

// Error page previews (local only)
if (app()->environment('local')) {
    Route::prefix('error-preview')->name('error-preview.')->group(function () {
        Route::get('/{status}', function (int $status) {
            return Inertia::render('Error', ['status' => $status]);
        })->where('status', '403|404|419|429|500|503')->name('inertia');
    });
}
