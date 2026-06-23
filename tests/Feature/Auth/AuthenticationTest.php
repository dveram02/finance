<?php

namespace Tests\Feature\Auth;

use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

class AuthenticationTest extends TestCase
{
    use RefreshDatabase;

    // Credential validation runs against the external SQL Server (vw_WebAppUsers)
    // via SWRHAUserProvider, which the test environment can't reach — so the
    // password-auth path isn't exercised here. These cover only what's local:
    // the login screen renders, and an authenticated user can log out.

    public function test_login_screen_can_be_rendered(): void
    {
        $this->get('/login')->assertOk();
    }

    public function test_users_can_logout(): void
    {
        $user = User::factory()->create();

        $response = $this->actingAs($user)->post('/logout');

        $this->assertGuest();
        $response->assertRedirect('/');
    }
}
