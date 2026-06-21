<?php

namespace App\Http\Middleware;

use App\Models\GP\SWRHAExpenseControlUser;
use Closure;
use Illuminate\Http\Request;
use Illuminate\Support\Facades\Auth;
use Symfony\Component\HttpFoundation\Response;

class EnsureUserIsActive
{
    // Re-verify against SQL Server at most once per 5 minutes per session.
    private const VERIFY_INTERVAL_MINUTES = 5;

    // After a SQL Server outage, retry sooner than the full interval so a
    // genuinely deactivated user isn't stranded active for the whole window.
    private const OUTAGE_RETRY_MINUTES = 1;

    public function handle(Request $request, Closure $next): Response
    {
        $user = Auth::user();

        if (! $user) {
            return $next($request);
        }

        if ($this->shouldReverify($user)) {
            $this->reverify($user);
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

    private function shouldReverify($user): bool
    {
        return is_null($user->sql_server_verified_at)
            || $user->sql_server_verified_at->diffInMinutes(now()) >= self::VERIFY_INTERVAL_MINUTES;
    }

    private function reverify($user): void
    {
        try {
            $sqlUser = SWRHAExpenseControlUser::where('UserName', $user->username)->first();
        } catch (\Throwable) {
            // SQL Server unavailable. A connection failure must NEVER deactivate the
            // user, so leave is_active untouched. Only back off OUTAGE_RETRY_MINUTES
            // (not the full interval) so a recently deactivated user isn't stranded
            // active, and we don't hammer a down server on every request.
            $user->sql_server_verified_at = now()
                ->subMinutes(self::VERIFY_INTERVAL_MINUTES - self::OUTAGE_RETRY_MINUTES);
            $user->save();

            return;
        }

        // Query succeeded — this result is authoritative. A missing row means the
        // account was removed in the source system, so deactivating is correct here.
        $user->is_active = (bool) ($sqlUser?->IsActive ?? false);
        $user->sql_server_verified_at = now();
        $user->save();
    }
}
