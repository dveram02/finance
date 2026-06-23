<?php

namespace Database\Factories;

use App\Models\User;
use Illuminate\Database\Eloquent\Factories\Factory;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Str;

/**
 * @extends Factory<User>
 */
class UserFactory extends Factory
{
    /**
     * The current password being used by the factory.
     */
    protected static ?string $password;

    /**
     * Define the model's default state.
     *
     * Mirrors the local `users` table, which is a cache of the SQL Server
     * `vw_WebAppUsers` record. `sql_server_verified_at` defaults to now() so
     * authenticated tests don't trip `active.user` reverification (a 5-min-stale
     * timestamp would force a live SQL Server query the test environment lacks).
     *
     * @return array<string, mixed>
     */
    public function definition(): array
    {
        return [
            'name' => fake()->name(),
            'username' => fake()->unique()->userName(),
            'employee_id' => (string) fake()->unique()->numberBetween(1000, 999999),
            'password' => static::$password ??= Hash::make('password'),
            'is_active' => true,
            'sql_server_verified_at' => now(),
            'remember_token' => Str::random(10),
        ];
    }

    public function inactive(): static
    {
        return $this->state(fn (array $attributes) => [
            'is_active' => false,
        ]);
    }
}
