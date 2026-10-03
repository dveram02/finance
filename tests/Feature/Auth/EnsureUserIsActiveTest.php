<?php

namespace Tests\Feature\Auth;

use App\Http\Middleware\EnsureUserIsActive;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\DB;
use Illuminate\Testing\TestResponse;
use Tests\Feature\Concerns\FakesExpenseControlDirectory;
use Tests\TestCase;

/**
 * The `active.user` middleware, which had NO test file until 2026-10-03.
 *
 * Every other suite disables it with withoutMiddleware(), so its reverification
 * path — including the rule that a SQL Server outage must never deactivate
 * anyone — had never been exercised. It is the only thing standing between a
 * revoked account and every page of financial data in the portal, so it gets
 * its own coverage.
 *
 * Runs entirely offline against the SQLite directory fake, like LoginFlowTest.
 */
class EnsureUserIsActiveTest extends TestCase
{
    use FakesExpenseControlDirectory;
    use RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();

        $this->fakeExpenseControlDirectory();
    }

    /**
     * A user whose last check is older than the 5-minute interval, so the next
     * request is forced to re-read the directory.
     */
    private function staleUser(array $attributes = []): User
    {
        return User::factory()->create(array_merge([
            'username' => 'FFIGUERA1',
            'name' => 'FRANCIS FIGUERA',
            'is_active' => true,
            'sql_server_verified_at' => now()->subMinutes(10),
        ], $attributes));
    }

    private function assertLoggedOutAsDeactivated(TestResponse $response): void
    {
        $this->assertGuest();
        $response->assertRedirect(route('login'));
        $response->assertSessionHas('error', 'Your account has been deactivated. Please contact an administrator.');
    }

    // =========================================================================
    // The string flag — the defect this file was written for
    // =========================================================================

    /**
     * The headline case. IsActive is a varchar holding 'FALSE', and the bare
     * (bool) cast this middleware used until 2026-10-03 read that as TRUE — so
     * a revoked account kept full access to every page in the portal.
     */
    public function test_the_string_false_deactivates_the_user(): void
    {
        $this->directoryUser(['IsActive' => 'FALSE']);
        $user = $this->staleUser();

        $this->assertTrue((bool) 'FALSE', 'sanity: the PHP trap this guards against');

        $response = $this->actingAs($user)->get('/profile');

        $this->assertLoggedOutAsDeactivated($response);
        $this->assertFalse((bool) $user->fresh()->is_active, 'the local mirror must be written through');
    }

    public function test_the_string_true_lets_the_user_through(): void
    {
        $this->directoryUser(['IsActive' => 'TRUE']);
        $user = $this->staleUser();

        $this->actingAs($user)->get('/profile')->assertOk();

        $this->assertAuthenticated();
        $this->assertTrue((bool) $user->fresh()->is_active);
    }

    public function test_an_unrecognised_flag_value_fails_closed(): void
    {
        // 'Y' is the shape a future source-system change could plausibly take.
        // It must lock the user out, not let them in.
        $this->directoryUser(['IsActive' => 'Y']);
        $user = $this->staleUser();

        $this->assertLoggedOutAsDeactivated($this->actingAs($user)->get('/profile'));
    }

    public function test_a_blank_flag_fails_closed(): void
    {
        $this->directoryUser(['IsActive' => '']);
        $user = $this->staleUser();

        $this->assertLoggedOutAsDeactivated($this->actingAs($user)->get('/profile'));
    }

    /**
     * Kept so the fix is provably backward compatible with the boolean the
     * fake used to store and some drivers still return.
     */
    public function test_a_boolean_false_still_deactivates(): void
    {
        $this->directoryUser(['IsActive' => false]);
        $user = $this->staleUser();

        $this->assertLoggedOutAsDeactivated($this->actingAs($user)->get('/profile'));
    }

    // =========================================================================
    // The other two outcomes of a reverification
    // =========================================================================

    public function test_a_missing_directory_row_deactivates(): void
    {
        // No directoryUser() at all: the account was removed upstream, and the
        // query SUCCEEDED in saying so. That is a real deactivation.
        $user = $this->staleUser();

        $this->assertLoggedOutAsDeactivated($this->actingAs($user)->get('/profile'));
        $this->assertFalse((bool) $user->fresh()->is_active);
    }

    /**
     * 🔴 The rule that matters most, and the one that had never been tested: a
     * SQL Server failure must NEVER deactivate anybody. Treating a connection
     * error as "inactive" would log every user out on a transient outage and
     * corrupt the local mirror on the way.
     */
    public function test_a_source_outage_does_not_deactivate_anyone(): void
    {
        $this->directoryUser();
        $user = $this->staleUser();

        DB::connection('SWRHAExpenseControl')->statement('DROP TABLE vw_WebAppUsers');

        $this->actingAs($user)->get('/profile')->assertOk();

        $this->assertAuthenticated();
        $this->assertTrue((bool) $user->fresh()->is_active, 'an outage must leave is_active untouched');
    }

    public function test_an_outage_backs_off_only_briefly_so_the_next_request_retries(): void
    {
        config(['auth.active_check.ttl_seconds' => 60, 'auth.active_check.outage_retry_seconds' => 15]);

        $this->directoryUser();
        $user = $this->staleUser();

        DB::connection('SWRHAExpenseControl')->statement('DROP TABLE vw_WebAppUsers');

        $this->actingAs($user)->get('/profile')->assertOk();

        // Stamped at (ttl - retry) = 45s ago, so the window has 15s left: the
        // next request a few seconds from now will NOT retry, but one 15s from
        // now will. That is the whole point - a genuinely revoked user is not
        // stranded for the full window, and a server we already know is down is
        // not re-queried on every single request in the meantime.
        $age = (int) round($user->fresh()->sql_server_verified_at->diffInSeconds(now()));

        $this->assertGreaterThanOrEqual(43, $age, 'backed off too little - would hammer a down server');
        $this->assertLessThanOrEqual(47, $age, 'backed off too much - would delay the retry');
    }

    public function test_an_outage_does_not_re_query_on_the_very_next_request(): void
    {
        config(['auth.active_check.ttl_seconds' => 60, 'auth.active_check.outage_retry_seconds' => 15]);

        $this->directoryUser();
        $user = $this->staleUser();

        DB::connection('SWRHAExpenseControl')->statement('DROP TABLE vw_WebAppUsers');
        $this->actingAs($user)->get('/profile')->assertOk();

        DB::connection('SWRHAExpenseControl')->enableQueryLog();
        $this->actingAs($user)->get('/profile')->assertOk();

        $this->assertCount(0, DB::connection('SWRHAExpenseControl')->getQueryLog());
    }

    // =========================================================================
    // The 5-minute interval itself
    // =========================================================================

    /**
     * A recently verified user must not re-query. The auth SQL Server is remote
     * and shared, so this is what keeps the portal from issuing one directory
     * lookup per page view.
     *
     * The window is bounded PER USER, not per session: the timestamp lives on
     * the `users` row, so every session and tab that user has open shares one
     * lookup per window. That is what made shortening it from 300s to 60s
     * cheap.
     */
    public function test_a_recently_verified_user_is_not_re_queried(): void
    {
        $this->directoryUser(['IsActive' => 'FALSE']);

        $user = $this->staleUser(['sql_server_verified_at' => now()->subSeconds(5)]);

        DB::connection('SWRHAExpenseControl')->enableQueryLog();

        $this->actingAs($user)->get('/profile')->assertOk();

        $this->assertCount(0, DB::connection('SWRHAExpenseControl')->getQueryLog());
        $this->assertAuthenticated();
    }

    /**
     * The exact boundary, both sides of it. Stale AT the window, not after it:
     * at ttl-1 seconds the mirror is still trusted and no query is issued; at
     * exactly ttl the directory is re-read and the revocation lands.
     */
    public function test_no_query_is_issued_one_second_before_the_window_expires(): void
    {
        config(['auth.active_check.ttl_seconds' => 60]);

        $this->directoryUser(['IsActive' => 'FALSE']);
        $user = $this->staleUser(['sql_server_verified_at' => now()->subSeconds(59)]);

        DB::connection('SWRHAExpenseControl')->enableQueryLog();

        $this->actingAs($user)->get('/profile')->assertOk();

        $this->assertCount(0, DB::connection('SWRHAExpenseControl')->getQueryLog());
        $this->assertAuthenticated();
    }

    public function test_the_revocation_lands_exactly_at_the_window(): void
    {
        config(['auth.active_check.ttl_seconds' => 60]);

        $this->directoryUser(['IsActive' => 'FALSE']);
        $user = $this->staleUser(['sql_server_verified_at' => now()->subSeconds(60)]);

        $this->assertLoggedOutAsDeactivated($this->actingAs($user)->get('/profile'));
    }

    public function test_the_window_is_configurable(): void
    {
        config(['auth.active_check.ttl_seconds' => 300]);

        $this->directoryUser(['IsActive' => 'FALSE']);

        // 120s old: stale under the 60s default, still fresh under 300s.
        $user = $this->staleUser(['sql_server_verified_at' => now()->subSeconds(120)]);

        $this->actingAs($user)->get('/profile')->assertOk();
        $this->assertAuthenticated();
    }

    /**
     * A misconfigured window must not become "trust forever". Garbage
     * normalises to the 60s default, so the revocation still lands.
     */
    public function test_a_garbage_window_falls_back_to_the_default_rather_than_trusting_forever(): void
    {
        config(['auth.active_check.ttl_seconds' => 'not-a-number']);

        $this->directoryUser(['IsActive' => 'FALSE']);
        $user = $this->staleUser(['sql_server_verified_at' => now()->subSeconds(61)]);

        $this->assertLoggedOutAsDeactivated($this->actingAs($user)->get('/profile'));
    }

    /**
     * A stamp in the FUTURE means the clock moved backwards. Carbon 3's
     * diffInMinutes() is signed, so the arithmetic this replaced returned a
     * negative and silently skipped the check until real time caught up.
     */
    public function test_a_future_timestamp_is_treated_as_stale_not_as_fresh(): void
    {
        $this->directoryUser(['IsActive' => 'FALSE']);
        $user = $this->staleUser(['sql_server_verified_at' => now()->addMinutes(30)]);

        $this->assertLoggedOutAsDeactivated($this->actingAs($user)->get('/profile'));
    }

    public function test_a_never_verified_user_is_always_re_queried(): void
    {
        $this->directoryUser(['IsActive' => 'FALSE']);

        $user = $this->staleUser(['sql_server_verified_at' => null]);

        $this->assertLoggedOutAsDeactivated($this->actingAs($user)->get('/profile'));
    }

    // =========================================================================
    // Name resync, which shares the same reverification
    // =========================================================================

    public function test_a_renamed_employee_is_resynced_without_a_re_login(): void
    {
        $this->directoryUser(['EmployeeName' => 'FRANCIS A FIGUERA']);
        $user = $this->staleUser(['name' => 'FRANCIS FIGUERA']);

        $this->actingAs($user)->get('/profile')->assertOk();

        $this->assertSame('FRANCIS A FIGUERA', $user->fresh()->name);
    }

    public function test_the_middleware_is_actually_registered_on_the_authenticated_group(): void
    {
        // Guards against the whole file silently passing because the alias was
        // dropped from routes/web.php. gatherMiddleware() reports the ALIAS,
        // unresolved, so assert the alias and that it still maps to the class.
        $this->assertContains(
            'active.user',
            app('router')->getRoutes()->getByName('profile.view')->gatherMiddleware()
        );

        $this->assertSame(
            EnsureUserIsActive::class,
            app('router')->getMiddleware()['active.user'] ?? null
        );
    }
}
