<?php

use App\Http\Controllers\Auth\AuthenticatedSessionController;
use App\Http\Controllers\DashboardController;
use App\Http\Controllers\ProfileController;
use Illuminate\Support\Facades\Route;

Route::get('/', fn () => redirect()->route('dashboard'));

// Guest routes
Route::middleware('guest')->group(function () {
    Route::get('/login',  [AuthenticatedSessionController::class, 'create'])->name('login');
    Route::post('/login', [AuthenticatedSessionController::class, 'store'])
        ->middleware('throttle:login')
        ->name('login.store');
});

// Authenticated routes
Route::middleware(['auth', 'active.user'])->group(function () {
    Route::get('/dashboard', [DashboardController::class, 'index'])->name('dashboard');
    Route::get('/profile',   [ProfileController::class, 'view'])->name('profile.view');
});

// Logout
Route::post('/logout', [AuthenticatedSessionController::class, 'destroy'])
    ->middleware('auth')
    ->name('logout');

// Error page previews (local only)
if (app()->environment('local')) {
    Route::prefix('error-preview')->name('error-preview.')->group(function () {
        Route::get('/{status}', function (int $status) {
            return \Inertia\Inertia::render('Error', ['status' => $status]);
        })->where('status', '403|404|419|429|500|503')->name('inertia');
    });
}
