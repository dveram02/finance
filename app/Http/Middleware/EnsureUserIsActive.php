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

    public function handle(Request $request, Closure $next): Response
    {
        $user = Auth::user();

        if (!$user) {
            return $next($request);
        }

        if ($this->shouldReverify($user)) {
            $sqlUser = $this->fetchSqlServerUser($user->username);

            $isActive = $sqlUser && (bool) $sqlUser->IsActive;

            $user->is_active = $isActive;
            $user->sql_server_verified_at = now();
            $user->save();
        }

        if (!$user->is_active) {
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

    private function fetchSqlServerUser(string $username): ?SWRHAExpenseControlUser
    {
        try {
            return SWRHAExpenseControlUser::where('UserName', $username)->first();
        } catch (\Throwable) {
            // SQL Server unavailable — preserve current is_active rather than locking everyone out.
            return null;
        }
    }
}
