<?php

use App\Http\Controllers\AllocationLineExpenditureController;
use App\Http\Controllers\Auth\AuthenticatedSessionController;
use App\Http\Controllers\BudgetAllocationController;
use App\Http\Controllers\DashboardController;
use App\Http\Controllers\DepartmentExpenditureController;
use App\Http\Controllers\EncumberedDetailsController;
use App\Http\Controllers\MonthlyExpenditureController;
use App\Http\Controllers\ProfileController;
use App\Http\Controllers\RoutingDetailsController;
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
    Route::get('/monthly-expenditure', [MonthlyExpenditureController::class, 'index'])->name('monthly-expenditure.index');
    Route::get('/department-expenditure', [DepartmentExpenditureController::class,   'index'])->name('department-expenditure.index');
    Route::get('/allocation-line-expenditure', [AllocationLineExpenditureController::class, 'index'])->name('allocation-line-expenditure.index');

    // Requisition-line drill-downs behind the ledger's Approved and Routing
    // columns (Phase 3). Same access rule as every other page — the department
    // mapping is inherited through vw_WebAppUserAccess, and there are no roles.
    Route::get('/encumbered-details', [EncumberedDetailsController::class, 'index'])->name('encumbered-details.index');
    Route::get('/routing-details', [RoutingDetailsController::class,  'index'])->name('routing-details.index');
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
