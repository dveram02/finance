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
            $dirty = false;

            if ((bool) $localUser->is_active !== (bool) $sqlUser->IsActive) {
                $localUser->is_active = (bool) $sqlUser->IsActive;
                $dirty = true;
            }

            $localUser->sql_server_verified_at = now();
            $dirty = true;

            if ($dirty) {
                $localUser->save();
            }
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

    private function createLocalUser(SWRHAExpenseControlUser $sqlUser): User
    {
        return User::create([
            'name' => $sqlUser->UserName,
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
