<?php

namespace Database\Factories;

use Illuminate\Database\Eloquent\Factories\Factory;
use Illuminate\Support\Facades\Hash;
use Illuminate\Support\Str;

/**
 * @extends \Illuminate\Database\Eloquent\Factories\Factory<\App\Models\User>
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
     * @return array<string, mixed>
     */
    public function definition(): array
    {
        return [
            'name'                  => fake()->name(),
            'email'                 => fake()->unique()->safeEmail(),
            'email_verified_at'     => now(),
            'password'              => static::$password ??= Hash::make('password'),
            'remember_token'        => Str::random(10),
            'status'                => 'ACTIVE',
            'must_change_password'  => false,
            'failed_login_attempts' => 0,
        ];
    }

    public function unverified(): static
    {
        return $this->state(fn (array $attributes) => [
            'email_verified_at' => null,
        ]);
    }

    public function pendingFirstLogin(): static
    {
        return $this->state(fn (array $attributes) => [
            'status'               => 'PENDING_FIRST_LOGIN',
            'must_change_password' => true,
        ]);
    }

    public function locked(): static
    {
        return $this->state(fn (array $attributes) => [
            'status'                => 'LOCKED',
            'failed_login_attempts' => 5,
            'locked_at'             => now(),
        ]);
    }

    public function inactive(): static
    {
        return $this->state(fn (array $attributes) => [
            'status' => 'INACTIVE',
        ]);
    }

    public function suspended(): static
    {
        return $this->state(fn (array $attributes) => [
            'status' => 'SUSPENDED',
        ]);
    }
}
