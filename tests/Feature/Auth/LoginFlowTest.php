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

    /**
     * The same two cases again with the value production actually stores.
     *
     * IsActive is a varchar holding 'TRUE'/'FALSE', and (bool) 'FALSE' is true
     * in PHP - so until 2026-10-03 a revoked account logged in normally. The
     * boolean-based cases above are kept for compatibility; these are the ones
     * that would have caught it.
     */
    public function test_the_string_false_blocks_a_first_time_login(): void
    {
        $this->directoryUser(['IsActive' => 'FALSE']);

        $response = $this->post('/login', [
            'username' => 'FFIGUERA1',
            'password' => self::PASSWORD,
        ]);

        $this->assertGuest();
        $response->assertSessionHas('error', 'Your account has been deactivated. Please contact an administrator.');
        $response->assertSessionHasNoErrors();

        // The mirror is still created - the provider returns the inactive user
        // deliberately so the controller can give the right message - but it
        // must be created INACTIVE.
        $this->assertFalse((bool) User::where('username', 'FFIGUERA1')->value('is_active'));
    }

    public function test_the_string_false_flips_an_existing_active_mirror(): void
    {
        $this->directoryUser(['IsActive' => 'FALSE']);
        User::factory()->create(['username' => 'FFIGUERA1', 'is_active' => true]);

        $this->post('/login', ['username' => 'FFIGUERA1', 'password' => self::PASSWORD]);

        $this->assertGuest();
        $this->assertFalse((bool) User::where('username', 'FFIGUERA1')->value('is_active'));
    }

    public function test_the_string_true_still_permits_login(): void
    {
        $this->directoryUser(['IsActive' => 'TRUE']);

        $this->post('/login', ['username' => 'FFIGUERA1', 'password' => self::PASSWORD]);

        $this->assertAuthenticated();
        $this->assertTrue((bool) User::where('username', 'FFIGUERA1')->value('is_active'));
    }

    public function test_an_unrecognised_active_flag_fails_closed_at_login(): void
    {
        $this->directoryUser(['IsActive' => 'Y']);

        $response = $this->post('/login', ['username' => 'FFIGUERA1', 'password' => self::PASSWORD]);

        $this->assertGuest();
        $response->assertSessionHas('error', 'Your account has been deactivated. Please contact an administrator.');
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

    /**
     * EXPECTATION CHANGED 2026-10-03, deliberately.
     *
     * This used to assert `assertSessionHasErrors('username')` — i.e. it locked
     * in the behaviour that an outage was reported as a credential failure. That
     * told anyone with a correct password that it was wrong, during an outage
     * nothing else on this deployment reports, and sent them to get a password
     * reset that was never needed. The provider now throws
     * DirectoryUnavailableException and the controller says so honestly.
     */
    public function test_a_sql_server_outage_is_reported_as_an_outage_not_a_bad_password(): void
    {
        // The directory table does not exist on this connection, so every query throws.
        DB::connection('SWRHAExpenseControl')->statement('DROP TABLE vw_WebAppUsers');

        $response = $this->post('/login', ['username' => 'FFIGUERA1', 'password' => self::PASSWORD]);

        $this->assertGuest();
        $response->assertRedirect(route('login'));

        // Still no 500, and still no 'username' field error blaming the user.
        $response->assertSessionHasNoErrors();
        $response->assertSessionHas('error', fn ($message) => str_contains($message, 'temporarily unavailable'));

        // The username survives so they are not retyping it on every retry.
        $response->assertSessionHasInput('username', 'FFIGUERA1');
    }

    /**
     * The other half of the same guard: a genuine bad password must STILL get
     * the generic credential error. If the outage change had leaked into this
     * path, every failed login would read as a system fault and real typos
     * would look like someone else's problem.
     */
    public function test_a_wrong_password_still_gets_the_generic_credential_error(): void
    {
        $this->directoryUser();

        $response = $this->post('/login', ['username' => 'FFIGUERA1', 'password' => 'wrong']);

        $this->assertGuest();
        $response->assertSessionHasErrors('username');
        $response->assertSessionMissing('error');
    }

    public function test_an_unknown_username_during_an_outage_is_also_reported_as_an_outage(): void
    {
        // The directory cannot answer "does this user exist?", so the honest
        // answer is the outage, not "no such user" — and it must not become a
        // user-enumeration oracle either way.
        DB::connection('SWRHAExpenseControl')->statement('DROP TABLE vw_WebAppUsers');

        $response = $this->post('/login', ['username' => 'NOBODY9', 'password' => 'whatever']);

        $this->assertGuest();
        $response->assertSessionHasNoErrors();
        $response->assertSessionHas('error', fn ($message) => str_contains($message, 'temporarily unavailable'));
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
