<?php

namespace App\Providers;

use App\Auth\SWRHAUserProvider;
use Illuminate\Cache\RateLimiting\Limit;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\RateLimiter;
use Illuminate\Support\ServiceProvider;

class AppServiceProvider extends ServiceProvider
{
    public function register(): void {}

    public function boot(): void
    {
        Auth::provider('swrha_expense_control', function ($app, array $config) {
            return new SWRHAUserProvider($config['model']);
        });

        RateLimiter::for('login', function (Request $request) {
            return Limit::perMinute(5)->by($request->input('username').'|'.$request->ip());
        });
    }
}
