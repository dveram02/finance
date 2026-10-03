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

        // Keyed on the authenticated user, NOT on username|ip: this route sits
        // behind auth, and sharing a counter with 'login' would mean a fumbled
        // password change locked someone out of signing in.
        //
        // The response() callback is not optional. A 429 on an Inertia request
        // renders Pages/Error.vue (see bootstrap/app.php), which would throw the
        // user off /profile and discard the form they were filling in.
        RateLimiter::for('password-change', function (Request $request) {
            return Limit::perMinute(6)
                ->by((string) ($request->user()?->getAuthIdentifier() ?? $request->ip()))
                ->response(fn () => back()->with(
                    'error',
                    'Too many password change attempts. Please wait a minute and try again.'
                ));
        });
    }
}
