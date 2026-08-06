<?php

namespace Tests\Feature\Auth;

use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Auth;
use Illuminate\Support\Facades\DB;
use Tests\Feature\Concerns\FakesExpenseControlDirectory;
use Tests\TestCase;

/**
 * The login flow end to end: SWRHAUserProvider against the (faked) auth SQL
 * Server, the local users mirror it maintains, and AuthenticatedSessionController.
 *
 * Everything here runs offline — see FakesExpenseControlDirectory.
 */
class LoginFlowTest extends TestCase
{
    use FakesExpenseControlDirectory;
    use RefreshDatabase;

    private const PASSWORD = 'correct-horse-battery';

    protected function setUp(): void
    {
        parent::setUp();

        $this->fakeExpenseControlDirectory();
    }

    // =========================================================================
    // Happy path
    // =========================================================================

    public function test_valid_credentials_log_the_user_in(): void
    {
        $this->directoryUser();

        $response = $this->post('/login', [
            'username' => 'FFIGUERA1',
            'password' => self::PASSWORD,
        ]);

        $this->assertAuthenticated();
        $response->assertRedirect('/dashboard');
    }

    public function test_first_login_creates_the_local_mirror_from_the_directory_row(): void
    {
        // A zero-padded EmployeeID: the padding must survive into the local
        // record. Casting it to int is the classic bug here.
        $this->directoryUser(['EmployeeID' => '000123', 'EmployeeName' => 'Felicia Figuera']);

        $this->post('/login', ['username' => 'FFIGUERA1', 'password' => self::PASSWORD]);

        $user = User::where('username', 'FFIGUERA1')->firstOrFail();

        $this->assertSame('Felicia Figuera', $user->name);   // EmployeeName, not UserName
        $this->assertSame('000123', $user->employee_id);
        $this->assertTrue($user->is_active);
        $this->assertNotNull($user->sql_server_verified_at);
    }

    public function test_display_name_falls_back_to_username_when_employee_name_is_missing(): void
    {
        // EmployeeName comes from a LEFT JOIN to the arrears DB, so it is NULL
        // for anyone with no matching employee record. The name must never be
        // empty — the whole UI binds auth.user.name.
        $this->directoryUser(['EmployeeName' => null]);

        $this->post('/login', ['username' => 'FFIGUERA1', 'password' => self::PASSWORD]);

        $this->assertSame('FFIGUERA1', User::where('username', 'FFIGUERA1')->value('name'));
    }

    public function test_login_resyncs_name_and_active_status_from_the_directory(): void
    {
        // The local row is a cache of the source system, not the source of truth.
        $this->directoryUser(['EmployeeName' => 'Felicia Figuera-Mohammed']);

        User::factory()->create([
            'username' => 'FFIGUERA1',
            'name' => 'Stale Name',
            'sql_server_verified_at' => now()->subDay(),
        ]);

        $this->post('/login', ['username' => 'FFIGUERA1', 'password' => self::PASSWORD]);

        $user = User::where('username', 'FFIGUERA1')->firstOrFail();

        $this->assertSame('Felicia Figuera-Mohammed', $user->name);
        $this->assertTrue($user->sql_server_verified_at->isAfter(now()->subMinute()));
    }

    // =========================================================================
    // Rejections
    // =========================================================================

    public function test_a_wrong_password_is_rejected(): void
    {
        $this->directoryUser();

        $response = $this->post('/login', [
            'username' => 'FFIGUERA1',
            'password' => 'not-the-password',
        ]);

        $this->assertGuest();
        $response->assertRedirect(route('login'));
        $response->assertSessionHasErrors('username');
    }

    public function test_an_unknown_username_is_rejected(): void
    {
        $response = $this->post('/login', [
            'username' => 'NOBODY',
            'password' => self::PASSWORD,
        ]);

        $this->assertGuest();
        $response->assertSessionHasErrors('username');
        $this->assertDatabaseCount('users', 0);
    }

    public function test_a_failed_login_does_not_create_a_local_mirror_row(): void
    {
        // Otherwise anyone could populate the users table by guessing usernames.
        $this->directoryUser();

        $this->post('/login', ['username' => 'FFIGUERA1', 'password' => 'wrong']);

        $this->assertGuest();
        $this->assertDatabaseCount('users', 0);
    }

    public function test_a_deactivated_account_gets_the_deactivated_message_not_a_generic_failure(): void
    {
        // Active status is NOT a credential failure: the account exists and the
        // password is right, so the user must be told to contact an
        // administrator rather than left retrying a correct password.
        $this->directoryUser(['IsActive' => false]);

        $response = $this->post('/login', [
            'username' => 'FFIGUERA1',
            'password' => self::PASSWORD,
        ]);

        $this->assertGuest();
        $response->assertRedirect(route('login'));
        $response->assertSessionHas('error', 'Your account has been deactivated. Please contact an administrator.');
        $response->assertSessionHasNoErrors();
    }

    public function test_deactivation_in_the_directory_is_written_through_to_the_local_mirror(): void
    {
        $this->directoryUser(['IsActive' => false]);

        User::factory()->create(['username' => 'FFIGUERA1', 'is_active' => true]);

        $this->post('/login', ['username' => 'FFIGUERA1', 'password' => self::PASSWORD]);

        $this->assertFalse((bool) User::where('username', 'FFIGUERA1')->value('is_active'));
    }

    public function test_missing_credentials_are_rejected_by_validation(): void
    {
        $response = $this->post('/login', ['username' => '', 'password' => '']);

        $this->assertGuest();
        $response->assertSessionHasErrors(['username', 'password']);
    }

    // =========================================================================
    // The provider contract itself
    // =========================================================================

    public function test_validate_credentials_rejects_a_wrong_password_when_called_directly(): void
    {
        // Guards the landmine: a provider whose validateCredentials() returns an
        // unconditional true is only safe while every caller happens to resolve
        // the user through retrieveByCredentials() first. Any future
        // password-confirmation screen would call this directly.
        $this->directoryUser();

        $user = User::factory()->create(['username' => 'FFIGUERA1']);
        $provider = Auth::guard('web')->getProvider();

        $this->assertFalse($provider->validateCredentials($user, [
            'username' => 'FFIGUERA1',
            'password' => 'not-the-password',
        ]));

        $this->assertTrue($provider->validateCredentials($user, [
            'username' => 'FFIGUERA1',
            'password' => self::PASSWORD,
        ]));
    }

    public function test_a_login_attempt_hits_the_auth_sql_server_exactly_once(): void
    {
        // Every query here is a round trip to a remote SQL Server that also
        // serves the auth database for other applications. Two lookups per
        // attempt is the cost this flow was refactored to remove.
        $this->directoryUser();

        DB::connection('SWRHAExpenseControl')->enableQueryLog();

        $this->post('/login', ['username' => 'FFIGUERA1', 'password' => self::PASSWORD]);

        $this->assertAuthenticated();
        $this->assertCount(1, DB::connection('SWRHAExpenseControl')->getQueryLog());
    }

    public function test_a_sql_server_outage_fails_the_login_without_a_500(): void
    {
        // The directory table does not exist on this connection, so every query
        // throws — the provider must swallow it and report a failed login.
        DB::connection('SWRHAExpenseControl')->statement('DROP TABLE vw_WebAppUsers');

        $response = $this->post('/login', ['username' => 'FFIGUERA1', 'password' => self::PASSWORD]);

        $this->assertGuest();
        $response->assertRedirect(route('login'));
        $response->assertSessionHasErrors('username');
    }

    // =========================================================================
    // Throttling
    // =========================================================================

    public function test_login_is_throttled_after_five_failed_attempts(): void
    {
        $this->directoryUser();

        for ($attempt = 1; $attempt <= 5; $attempt++) {
            $this->post('/login', ['username' => 'FFIGUERA1', 'password' => 'wrong'])
                ->assertRedirect(route('login'));
        }

        $this->post('/login', ['username' => 'FFIGUERA1', 'password' => 'wrong'])
            ->assertStatus(429);

        // And the throttle holds even once the right password is offered.
        $this->post('/login', ['username' => 'FFIGUERA1', 'password' => self::PASSWORD])
            ->assertStatus(429);

        $this->assertGuest();
    }
}
