<?php

namespace Tests\Feature;

use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Inertia\Testing\AssertableInertia;
use Tests\TestCase;

class ProfileTest extends TestCase
{
    use RefreshDatabase;

    public function test_profile_page_is_displayed(): void
    {
        $user = User::factory()->create();

        $this->actingAs($user)
            ->get('/profile')
            ->assertOk()
            ->assertInertia(fn (AssertableInertia $page) => $page
                ->component('Profile/View Profile')
                ->where('user.name', $user->name)
                ->where('user.username', $user->username)
                ->where('user.employee_id', $user->employee_id)
            );
    }

    public function test_profile_page_requires_authentication(): void
    {
        $this->get('/profile')->assertRedirect('/login');
    }
}
