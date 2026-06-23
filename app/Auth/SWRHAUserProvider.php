<?php

namespace App\Auth;

use App\Models\GP\SWRHAExpenseControlUser;
use App\Models\User;
use Illuminate\Contracts\Auth\Authenticatable;
use Illuminate\Contracts\Auth\UserProvider;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Str;

class SWRHAUserProvider implements UserProvider
{
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

        $sqlUser = $this->findSqlServerUser($username);

        \Log::debug('SWRHAUserProvider', [
            'username' => $username,
            'sqlUser' => (bool) $sqlUser,
            'isActive' => $sqlUser?->IsActive,
            'pwMatch' => $sqlUser ? ($sqlUser->UserPassword === $password) : null,
        ]);

        if (! $sqlUser || ! $sqlUser->IsActive) {
            return null;
        }

        if ($sqlUser->UserPassword !== $password) {
            return null;
        }

        $localUser = User::where('username', $sqlUser->UserName)->first();

        if (! $localUser) {
            $localUser = $this->createLocalUser($sqlUser);
        } else {
            // Display name comes from EmployeeName (the arrears-DB join); sync it on
            // each login so a corrected name in the source system propagates here.
            $displayName = $this->resolveDisplayName($sqlUser);

            if ($localUser->name !== $displayName) {
                $localUser->name = $displayName;
            }

            if ((bool) $localUser->is_active !== (bool) $sqlUser->IsActive) {
                $localUser->is_active = (bool) $sqlUser->IsActive;
            }

            $localUser->sql_server_verified_at = now();
            $localUser->save();
        }

        return $localUser;
    }

    public function validateCredentials(Authenticatable $user, array $credentials): bool
    {
        return true;
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
