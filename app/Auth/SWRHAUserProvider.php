<?php

namespace App\Auth;

use App\Models\GP\SWRHAExpenseControlUser;
use App\Models\User;
use Illuminate\Contracts\Auth\Authenticatable;
use Illuminate\Contracts\Auth\UserProvider;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Str;

/**
 * Authenticates against SWRHAExpenseControl.dbo.vw_WebAppUsers and keeps the
 * local `users` table as a mirror of it.
 *
 * Division of labour, which is not the obvious one:
 *   - retrieveByCredentials() resolves the directory row, rejects a bad
 *     password, and syncs the local mirror. It deliberately does NOT reject an
 *     INACTIVE account — it returns the (synced, is_active = false) user so the
 *     login controller can say "your account has been deactivated" instead of
 *     "those credentials are wrong", which would leave someone retrying a
 *     password that is perfectly correct.
 *   - validateCredentials() re-checks the password against the row cached by
 *     the call above, so it is a real gate rather than an unconditional `true`
 *     that only happens to be safe because of how it is currently called.
 *
 * The directory row is cached on the instance for exactly this reason: the
 * guard calls both methods in sequence, and the auth SQL Server is remote and
 * shared with other applications, so a login attempt costs ONE round trip.
 */
class SWRHAUserProvider implements UserProvider
{
    /**
     * The directory row resolved by the most recent retrieveByCredentials(),
     * so validateCredentials() does not have to query for it again.
     */
    private ?SWRHAExpenseControlUser $resolvedSqlUser = null;

    public function __construct(protected string $model) {}

    public function retrieveById($identifier): ?Authenticatable
    {
        return ($this->model)::find($identifier);
    }

    public function retrieveByToken($identifier, $token): ?Authenticatable
    {
        $user = ($this->model)::find($identifier);

        if (! $user || $user->getRememberToken() !== $token) {
            return null;
        }

        return $user;
    }

    public function updateRememberToken(Authenticatable $user, $token): void
    {
        $user->setRememberToken($token);
        $user->save();
    }

    public function retrieveByCredentials(array $credentials): ?Authenticatable
    {
        $username = $credentials['username'] ?? null;
        $password = $credentials['password'] ?? null;

        if (! $username || ! $password) {
            return null;
        }

        // Never log the credential comparison here. A previous revision wrote
        // username + pwMatch to laravel.log on every attempt, which is a
        // password-match oracle in a plaintext log file.
        $sqlUser = $this->resolvedSqlUser = $this->findSqlServerUser($username);

        if (! $sqlUser) {
            return null;
        }

        // The password is checked here as well as in validateCredentials() —
        // not for authentication (the guard does that), but so a wrong guess
        // never reaches syncLocalUser(). Otherwise anyone could populate the
        // local users table just by guessing usernames.
        if (! $this->passwordMatches($sqlUser, $password)) {
            return null;
        }

        // An inactive account is returned, not rejected: see the class docblock.
        return $this->syncLocalUser($sqlUser);
    }

    /**
     * The real password gate.
     *
     * Uses the row already fetched by retrieveByCredentials() when it is the
     * same user, so the common path costs no extra round trip; falls back to a
     * lookup for any caller that resolved the user some other way (a
     * password-confirmation screen, say). Never return an unconditional true
     * here — that would make this method a no-op gate for every such caller.
     */
    public function validateCredentials(Authenticatable $user, array $credentials): bool
    {
        $username = $credentials['username'] ?? $user->getAuthIdentifierName();
        $password = $credentials['password'] ?? null;

        if (! $username || ! $password) {
            return false;
        }

        $sqlUser = $this->resolvedSqlUser?->UserName === $username
            ? $this->resolvedSqlUser
            : $this->findSqlServerUser($username);

        return $sqlUser !== null && $this->passwordMatches($sqlUser, $password);
    }

    public function rehashPasswordIfRequired(Authenticatable $user, array $credentials, bool $force = false): void {}

    private function findSqlServerUser(string $username): ?SWRHAExpenseControlUser
    {
        try {
            return SWRHAExpenseControlUser::where('UserName', $username)->first();
        } catch (\Throwable $e) {
            \Log::error('SWRHAUserProvider SQL Server error', ['message' => $e->getMessage()]);

            return null;
        }
    }

    /**
     * The user's display name for the UI (header, sidebar, profile).
     * Prefer EmployeeName from the arrears-DB join; fall back to UserName when
     * it is NULL (no matching arrears row) or blank so the name is never empty.
     */
    private function resolveDisplayName(SWRHAExpenseControlUser $sqlUser): string
    {
        $employeeName = trim((string) ($sqlUser->EmployeeName ?? ''));

        return $employeeName !== '' ? $employeeName : $sqlUser->UserName;
    }

    /**
     * Compare the supplied password against the directory row.
     *
     * vw_WebAppUsers stores passwords in PLAINTEXT — an external constraint,
     * the source system owns them, and this application cannot hash what it
     * does not write. hash_equals() is the mitigation that is available: it
     * removes the timing signal a plain !== comparison leaks.
     */
    private function passwordMatches(SWRHAExpenseControlUser $sqlUser, string $password): bool
    {
        return hash_equals((string) $sqlUser->UserPassword, $password);
    }

    /**
     * Create or refresh the local mirror of a directory row.
     *
     * `name` and `is_active` are caches of the source system, re-synced on
     * every login so a rename or a deactivation propagates without waiting for
     * the 5-minute EnsureUserIsActive reverification.
     */
    private function syncLocalUser(SWRHAExpenseControlUser $sqlUser): User
    {
        $localUser = User::where('username', $sqlUser->UserName)->first();

        if (! $localUser) {
            return $this->createLocalUser($sqlUser);
        }

        $localUser->name = $this->resolveDisplayName($sqlUser);
        $localUser->is_active = (bool) $sqlUser->IsActive;
        $localUser->sql_server_verified_at = now();
        $localUser->save();

        return $localUser;
    }

    private function createLocalUser(SWRHAExpenseControlUser $sqlUser): User
    {
        return User::create([
            'name' => $this->resolveDisplayName($sqlUser),
            'username' => $sqlUser->UserName,
            // EmployeeID is a string in SQL Server — never cast to int (that would
            // drop leading zeros / mangle non-numeric IDs). Trim padding, keep null.
            'employee_id' => $sqlUser->EmployeeID !== null ? trim((string) $sqlUser->EmployeeID) : null,
            'password' => Hash::make(Str::random(40)),
            'is_active' => (bool) $sqlUser->IsActive,
            'sql_server_verified_at' => now(),
        ]);
    }
}
