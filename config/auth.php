<?php

return [

    /*
    |--------------------------------------------------------------------------
    | Authentication Defaults
    |--------------------------------------------------------------------------
    |
    | This option defines the default authentication "guard" and password
    | reset "broker" for your application. You may change these values
    | as required, but they're a perfect start for most applications.
    |
    */

    'defaults' => [
        'guard' => env('AUTH_GUARD', 'web'),
        'passwords' => env('AUTH_PASSWORD_BROKER', 'users'),
    ],

    /*
    |--------------------------------------------------------------------------
    | Authentication Guards
    |--------------------------------------------------------------------------
    |
    | Next, you may define every authentication guard for your application.
    | Of course, a great default configuration has been defined for you
    | which utilizes session storage plus the Eloquent user provider.
    |
    | All authentication guards have a user provider, which defines how the
    | users are actually retrieved out of your database or other storage
    | system used by the application. Typically, Eloquent is utilized.
    |
    | Supported: "session"
    |
    */

    'guards' => [
        'web' => [
            'driver' => 'session',
            'provider' => 'users',
        ],
    ],

    /*
    |--------------------------------------------------------------------------
    | User Providers
    |--------------------------------------------------------------------------
    |
    | All authentication guards have a user provider, which defines how the
    | users are actually retrieved out of your database or other storage
    | system used by the application. Typically, Eloquent is utilized.
    |
    | If you have multiple user tables or models you may configure multiple
    | providers to represent the model / table. These providers may then
    | be assigned to any extra authentication guards you have defined.
    |
    | Supported: "database", "eloquent"
    |
    */

    'providers' => [
        'users' => [
            'driver' => 'swrha_expense_control',
            'model'  => App\Models\User::class,
        ],
    ],

    /*
    |--------------------------------------------------------------------------
    | Resetting Passwords
    |--------------------------------------------------------------------------
    |
    | These configuration options specify the behavior of Laravel's password
    | reset functionality, including the table utilized for token storage
    | and the user provider that is invoked to actually retrieve users.
    |
    | The expiry time is the number of minutes that each reset token will be
    | considered valid. This security feature keeps tokens short-lived so
    | they have less time to be guessed. You may change this as needed.
    |
    | The throttle setting is the number of seconds a user must wait before
    | generating more password reset tokens. This prevents the user from
    | quickly generating a very large amount of password reset tokens.
    |
    */

    'passwords' => [
        'users' => [
            'provider' => 'users',
            'table' => env('AUTH_PASSWORD_RESET_TOKEN_TABLE', 'password_reset_tokens'),
            'expire' => 60,
            'throttle' => 60,
        ],
    ],

    /*
    |--------------------------------------------------------------------------
    | Password Confirmation Timeout
    |--------------------------------------------------------------------------
    |
    | Here you may define the number of seconds before a password confirmation
    | window expires and users are asked to re-enter their password via the
    | confirmation screen. By default, the timeout lasts for three hours.
    |
    */

    'password_timeout' => env('AUTH_PASSWORD_TIMEOUT', 10800),

    /*
    |--------------------------------------------------------------------------
    | Active-Status Trust Window
    |--------------------------------------------------------------------------
    |
    | How long the `active.user` middleware may trust the local users.is_active
    | mirror before re-reading vw_WebAppUsers, and how soon it retries after a
    | failed read.
    |
    | The cost is bounded PER USER, not per request and not per session: the
    | timestamp lives on the users row, so every session and tab that user has
    | open shares one directory lookup per window.
    |
    | Lowered from 300s to 60s on 2026-10-03. Both values are normalised by
    | App\Support\ActiveCheckWindow, which fails closed in both directions:
    | 0 does NOT mean "check every request" (that would be a denial of service
    | against a remote, shared auth server) and a huge value does not mean
    | "never check". There is deliberately no way to switch the check off.
    |
    */

    'active_check' => [
        'ttl_seconds' => env('ACTIVE_USER_TTL_SECONDS', 60),
        'outage_retry_seconds' => env('ACTIVE_USER_OUTAGE_RETRY_SECONDS', 15),
    ],

    /*
    |--------------------------------------------------------------------------
    | Self-Service Directory Password Change
    |--------------------------------------------------------------------------
    |
    | The kill switch for the password-change card on /profile. It writes to
    | SWRHAExpenseControl.dbo.0006AWebAppControls, a table owned by another
    | team, so the application login needs a column-level GRANT that does not
    | exist by default (see sql/GrantPasswordUpdate.sql).
    |
    | Defaulting to false lets the code deploy BEFORE the grant is applied: the
    | route exists, the service refuses, and the card does not render. It is
    | also the rollback that needs no redeploy — flip it and run
    | `php artisan config:clear`.
    |
    */

    'directory_password_change' => env('DIRECTORY_PASSWORD_CHANGE', false),

];
