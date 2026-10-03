<?php

namespace App\Http\Middleware;

use App\Models\GP\SWRHAExpenseControlUser;
use App\Support\ActiveCheckWindow;
use App\Support\DirectoryFlag;
use Closure;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;
use Symfony\Component\HttpFoundation\Response;

/**
 * Re-verifies the authenticated user's active status against the directory.
 *
 * The trust window is bounded PER USER, not per session and not per request:
 * `sql_server_verified_at` lives on the local `users` row, so every session,
 * tab and request that user has open shares a single directory lookup per
 * window. (The comment here said "per session" until 2026-10-03 and was
 * wrong — it mattered, because it made the cost of shortening the window look
 * larger than it is.)
 *
 * The window is configuration, normalised by ActiveCheckWindow, and was
 * lowered from 300s to 60s on 2026-10-03: this is a finance application, and
 * five minutes of continued access after a deliberate revocation is longer
 * than it needs to be.
 */
class EnsureUserIsActive
{
    public function handle(Request $request, Closure $next): Response
    {
        $user = Auth::user();

        if (! $user) {
            return $next($request);
        }

        $window = $this->window();

        if ($this->shouldReverify($user, $window)) {
            $this->reverify($user, $window);
        }

        if (! $user->is_active) {
            Auth::logout();
            $request->session()->invalidate();
            $request->session()->regenerateToken();

            return redirect()->route('login')
                ->with('error', 'Your account has been deactivated. Please contact an administrator.');
        }

        return $next($request);
    }

    private function window(): ActiveCheckWindow
    {
        return ActiveCheckWindow::fromConfig(
            config('auth.active_check.ttl_seconds'),
            config('auth.active_check.outage_retry_seconds'),
        );
    }

    private function shouldReverify($user, ActiveCheckWindow $window): bool
    {
        $verifiedAt = $user->sql_server_verified_at;

        if (is_null($verifiedAt)) {
            return true;
        }

        // A stamp in the FUTURE means the clock moved backwards (an NTP
        // correction, say). It cannot be trusted, so re-verify rather than
        // coasting until real time catches up. Worth being explicit: Carbon 3's
        // diffInMinutes() is SIGNED, so the arithmetic this replaced would have
        // returned a negative and quietly skipped the check for that whole
        // period.
        if ($verifiedAt->isFuture()) {
            return true;
        }

        // Stale AT the boundary, not after it: with a 60s window, 59s still
        // trusts the mirror and 60s re-reads the directory.
        return $verifiedAt->copy()
            ->addSeconds($window->ttlSeconds)
            ->lessThanOrEqualTo(now());
    }

    private function reverify($user, ActiveCheckWindow $window): void
    {
        try {
            $sqlUser = SWRHAExpenseControlUser::where('UserName', $user->username)->first();
        } catch (\Throwable) {
            // SQL Server unavailable. A connection failure must NEVER deactivate
            // the user, so leave is_active untouched. Back off only
            // retrySeconds (not the full window) so a recently deactivated user
            // isn't stranded active — but back off at all, so a down server is
            // not re-queried on every single request.
            $user->sql_server_verified_at = now()->subSeconds($window->outageBackdateSeconds());
            $user->save();

            return;
        }

        // Query succeeded — this result is authoritative. A missing row means the
        // account was removed in the source system, so deactivating is correct here.
        //
        // DirectoryFlag, never a (bool) cast: IsActive is a varchar holding the
        // strings 'TRUE'/'FALSE', and (bool) 'FALSE' is true in PHP.
        $user->is_active = DirectoryFlag::isTrue($sqlUser?->IsActive ?? false);

        // Keep the display name (EmployeeName from the arrears-DB join) in sync so a
        // corrected name propagates without a re-login. Fall back to UserName when the
        // join yields no name. Skip when the row is gone (the user is being logged out).
        if ($sqlUser) {
            $employeeName = trim((string) ($sqlUser->EmployeeName ?? ''));
            $user->name = $employeeName !== '' ? $employeeName : $sqlUser->UserName;
        }

        $user->sql_server_verified_at = now();
        $user->save();
    }
}
