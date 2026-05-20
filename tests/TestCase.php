<?php

namespace Tests;

use Database\Seeders\RolesAndPermissionsSeeder;
use Illuminate\Foundation\Testing\TestCase as BaseTestCase;
use Spatie\Permission\Models\Role;

abstract class TestCase extends BaseTestCase
{
    /**
     * Seed roles and permissions. Call in setUp() for tests that need Spatie RBAC.
     * Safe to call multiple times — seeder uses updateOrCreate.
     */
    protected function seedPermissions(): void
    {
        $this->seed(RolesAndPermissionsSeeder::class);
        app()[\Spatie\Permission\PermissionRegistrar::class]->forgetCachedPermissions();
    }

    /**
     * Create a user and assign them the named role.
     */
    protected function userWithRole(string $roleName, array $attributes = []): \App\Models\User
    {
        $user = \App\Models\User::factory()->create($attributes);
        $user->assignRole($roleName);
        return $user;
    }
}
