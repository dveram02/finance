<?php

namespace Tests\Feature\Auth;

use App\Models\User;
use App\Support\DirectoryFlag;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\DB;
use Illuminate\Testing\TestResponse;
use Inertia\Testing\AssertableInertia;
use Tests\Feature\Concerns\FakesExpenseControlDirectory;
use Tests\TestCase;

/**
 * Covers the only write this application performs.
 *
 * Runs entirely offline against the SQLite directory fake, like LoginFlowTest
 * and for the same reason: this is security-relevant, a directory row is a
 * handful of columns, and a suite that skips when SQL Server is unreachable
 * would verify nothing on the machine where it matters most.
 */
class PasswordChangeTest extends TestCase
{
    use FakesExpenseControlDirectory;
    use RefreshDatabase;

    private const CURRENT = 'correct-horse-battery';

    private const REPLACEMENT = 'brand-new-secret';

    protected function setUp(): void
    {
        parent::setUp();

        $this->fakeExpenseControlDirectory();

        config(['auth.directory_password_change' => true]);
    }

    /** @param  array<string,mixed>  $attributes */
    private function actingAsDirectoryUser(array $attributes = []): User
    {
        $row = $this->directoryUser($attributes);

        $user = User::factory()->create([
            'username' => $row['UserName'],
            'name' => $row['EmployeeName'] ?? $row['UserName'],
            'employee_id' => $row['EmployeeID'],
            // DirectoryFlag, not (bool): with the fake now storing production's
            // strings, (bool) 'FALSE' would build an ACTIVE local mirror and
            // quietly defeat any fixture that sets the flag off.
            'is_active' => DirectoryFlag::isTrue($row['IsActive']),
        ]);

        $this->actingAs($user);

        return $user;
    }

    /** @param  array<string,mixed>  $overrides */
    private function change(array $overrides = []): TestResponse
    {
        return $this->post('/profile/password', array_merge([
            'current_password' => self::CURRENT,
            'password' => self::REPLACEMENT,
            'password_confirmation' => self::REPLACEMENT,
        ], $overrides));
    }

    private function storedPassword(string $username = 'FFIGUERA1'): ?string
    {
        return $this->directoryControlRowWhere(['UserName' => $username])?->UserPassword;
    }

    // =========================================================================
    // Happy path
    // =========================================================================

    public function test_a_valid_change_writes_the_new_password_to_the_directory(): void
    {
        $this->actingAsDirectoryUser();

        $this->change();

        $this->assertSame(self::REPLACEMENT, $this->storedPassword());
    }

    public function test_it_stamps_the_audit_columns_with_the_display_name(): void
    {
        $user = $this->actingAsDirectoryUser();

        $this->change();

        $row = $this->directoryControlRowWhere(['UserName' => 'FFIGUERA1']);

        // The directory stores a display name here, not a username — the
        // production rows read "FRANCIS FIGUERA", which is EmployeeName.
        $this->assertSame($user->name, $row->LastEditedBy);
        $this->assertMatchesRegularExpression('/^\d{4}-\d{2}-\d{2}$/', $row->DateEdited);
        $this->assertMatchesRegularExpression('/^\d{2}:\d{2}:\d{2}$/', $row->TimeEdited);
    }

    public function test_it_writes_nothing_but_the_password_and_the_audit_columns(): void
    {
        $this->actingAsDirectoryUser();

        $before = $this->directoryControlRowWhere(['UserName' => 'FFIGUERA1']);

        $this->change();

        $after = $this->directoryControlRowWhere(['LineID' => $before->LineID]);

        // PositionID in particular is the ACCESS-CONTROL key: vw_WebAppUserAccess
        // joins on it to decide whose departmental money a user can see, so a
        // write that reached it would be a privilege escalation.
        $untouched = ['LineID', 'EmployeeID', 'UserName', 'PositionID', 'IsActive', 'CreatedBy', 'DateCreated', 'TimeCreated'];

        foreach ($untouched as $column) {
            $this->assertSame($before->{$column}, $after->{$column}, "{$column} must not be written");
        }
    }

    public function test_it_redirects_to_the_profile_with_a_success_flash(): void
    {
        $this->actingAsDirectoryUser();

        $this->change()
            ->assertRedirect('/profile')
            ->assertSessionHas('success');
    }

    public function test_the_user_stays_signed_in_and_the_session_id_is_regenerated(): void
    {
        $this->actingAsDirectoryUser();

        $this->get('/profile');
        $before = session()->getId();

        $this->change();

        $this->assertAuthenticated();
        $this->assertNotSame($before, session()->getId());
    }

    public function test_it_rotates_the_remember_token_so_other_devices_are_signed_out(): void
    {
        $user = $this->actingAsDirectoryUser();
        $user->forceFill(['remember_token' => 'old-remember-token'])->save();

        $this->change();

        $rotated = $user->fresh()->remember_token;

        $this->assertNotNull($rotated);
        $this->assertNotSame('old-remember-token', $rotated);
    }

    public function test_the_local_mirror_password_hash_is_left_alone(): void
    {
        $user = $this->actingAsDirectoryUser();
        $hash = $user->password;

        $this->change();

        $this->assertSame($hash, $user->fresh()->password);
    }

    public function test_the_new_password_works_at_login_and_the_old_one_does_not(): void
    {
        $this->actingAsDirectoryUser();
        $this->change();

        // The fake keeps the view and its base table as two SQLite tables, so
        // propagate the way the real view would, then prove the write half and
        // the login half of the feature actually agree.
        DB::connection('SWRHAExpenseControl')->table('vw_WebAppUsers')
            ->where('UserName', 'FFIGUERA1')
            ->update(['UserPassword' => $this->storedPassword()]);

        $this->post('/logout');
        $this->assertGuest();

        $this->post('/login', ['username' => 'FFIGUERA1', 'password' => self::CURRENT]);
        $this->assertGuest();

        $this->post('/login', ['username' => 'FFIGUERA1', 'password' => self::REPLACEMENT]);
        $this->assertAuthenticated();
    }

    public function test_the_change_reads_the_control_row_exactly_once(): void
    {
        $this->actingAsDirectoryUser();
        $this->get('/profile');   // let active.user reverification settle first

        DB::connection('SWRHAExpenseControl')->enableQueryLog();

        $this->change();

        $selects = array_filter(
            DB::connection('SWRHAExpenseControl')->getQueryLog(),
            fn ($q) => str_starts_with(strtolower(trim($q['query'])), 'select')
                && str_contains($q['query'], '0006AWebAppControls')
        );

        // One read of the control row plus the post-write read-back verify.
        // More than that means someone routed the password check back through
        // SWRHAUserProvider and reintroduced the extra round trip to a remote,
        // shared auth server.
        $this->assertCount(2, $selects);
    }

    // =========================================================================
    // Rejections — each must leave the stored password untouched
    // =========================================================================

    public function test_a_wrong_current_password_is_rejected(): void
    {
        $this->actingAsDirectoryUser();

        $this->change(['current_password' => 'not-my-password'])
            ->assertSessionHasErrors('current_password');

        $this->assertSame(self::CURRENT, $this->storedPassword());
    }

    public function test_a_password_shorter_than_six_characters_is_rejected(): void
    {
        $this->actingAsDirectoryUser();

        $this->change(['password' => 'abcde', 'password_confirmation' => 'abcde'])
            ->assertSessionHasErrors('password');

        $this->assertSame(self::CURRENT, $this->storedPassword());
    }

    public function test_a_password_longer_than_sixty_four_characters_is_rejected(): void
    {
        $this->actingAsDirectoryUser();
        $long = str_repeat('a', 65);

        $this->change(['password' => $long, 'password_confirmation' => $long])
            ->assertSessionHasErrors('password');

        $this->assertSame(self::CURRENT, $this->storedPassword());
    }

    public function test_the_length_boundaries_themselves_are_accepted(): void
    {
        $this->actingAsDirectoryUser();

        $this->change(['password' => 'abcdef', 'password_confirmation' => 'abcdef']);
        $this->assertSame('abcdef', $this->storedPassword());

        $sixtyFour = str_repeat('b', 64);

        $this->post('/profile/password', [
            'current_password' => 'abcdef',
            'password' => $sixtyFour,
            'password_confirmation' => $sixtyFour,
        ]);

        $this->assertSame($sixtyFour, $this->storedPassword());
    }

    public function test_a_confirmation_mismatch_is_rejected(): void
    {
        $this->actingAsDirectoryUser();

        $this->change(['password_confirmation' => 'something-else'])
            ->assertSessionHasErrors('password');

        $this->assertSame(self::CURRENT, $this->storedPassword());
    }

    public function test_a_new_password_identical_to_the_current_one_is_rejected(): void
    {
        $this->actingAsDirectoryUser();

        $this->change(['password' => self::CURRENT, 'password_confirmation' => self::CURRENT])
            ->assertSessionHasErrors('password');

        $this->assertSame(self::CURRENT, $this->storedPassword());
    }

    /**
     * The lockout guard, and the most important rejection in this file.
     *
     * UserPassword is varchar COLLATE Latin1_General_CI_AS while the connection
     * sends nvarchar, so a codepoint outside CP1252 is silently replaced with
     * '?' — and this application has no password-reset route to recover with.
     */
    public function test_a_non_ascii_password_is_rejected(): void
    {
        $this->actingAsDirectoryUser();
        $accented = 'pa'.chr(0xC3).chr(0xA9).'ssword';

        $this->change(['password' => $accented, 'password_confirmation' => $accented])
            ->assertSessionHasErrors('password');

        $this->assertSame(self::CURRENT, $this->storedPassword());
    }

    public function test_a_password_containing_a_control_character_is_rejected(): void
    {
        $this->actingAsDirectoryUser();

        // The first of these proves the /D modifier on the regex: without it a
        // trailing newline slips past the $ anchor and defeats the guard.
        foreach (["abcdefg\n", "abc\tdefg", "abc\ndefg"] as $candidate) {
            $this->change(['password' => $candidate, 'password_confirmation' => $candidate])
                ->assertSessionHasErrors('password');
        }

        $this->assertSame(self::CURRENT, $this->storedPassword());
    }

    public function test_missing_fields_are_rejected_by_validation(): void
    {
        $this->actingAsDirectoryUser();

        $this->post('/profile/password', [])
            ->assertSessionHasErrors(['current_password', 'password']);

        $this->assertSame(self::CURRENT, $this->storedPassword());
    }

    // =========================================================================
    // Structural guards
    // =========================================================================

    public function test_an_ambiguous_username_refuses_and_writes_to_neither_row(): void
    {
        $this->actingAsDirectoryUser();
        $this->directoryControlRow(['UserName' => 'FFIGUERA1', 'UserPassword' => 'the-other-persons']);

        $this->change()->assertSessionHasErrors('current_password');

        $stored = DB::connection('SWRHAExpenseControl')->table('0006AWebAppControls')
            ->where('UserName', 'FFIGUERA1')
            ->pluck('UserPassword')
            ->all();

        $this->assertEqualsCanonicalizing([self::CURRENT, 'the-other-persons'], $stored);
    }

    public function test_a_missing_control_row_refuses_without_a_500(): void
    {
        $this->actingAsDirectoryUser();
        DB::connection('SWRHAExpenseControl')->table('0006AWebAppControls')->delete();

        $this->change()
            ->assertRedirect()
            ->assertSessionHasErrors('current_password');
    }

    public function test_a_source_outage_refuses_without_a_500_and_without_blaming_the_password(): void
    {
        $this->actingAsDirectoryUser();
        DB::connection('SWRHAExpenseControl')->statement('DROP TABLE "0006AWebAppControls"');

        $this->change()->assertRedirect();

        $message = session('errors')->get('current_password')[0];

        $this->assertStringContainsString('try again later', $message);
        $this->assertStringNotContainsString('incorrect', $message);
    }

    public function test_a_guest_is_redirected_to_login(): void
    {
        $this->directoryUser();

        $this->post('/profile/password', [
            'current_password' => self::CURRENT,
            'password' => self::REPLACEMENT,
            'password_confirmation' => self::REPLACEMENT,
        ])->assertRedirect('/login');

        $this->assertSame(self::CURRENT, $this->storedPassword());
    }

    public function test_a_deactivated_user_is_bounced_before_the_controller(): void
    {
        $row = $this->directoryUser(['IsActive' => false]);

        $user = User::factory()->inactive()->create([
            'username' => $row['UserName'],
            'name' => $row['EmployeeName'],
        ]);

        $this->actingAs($user)
            ->post('/profile/password', [
                'current_password' => self::CURRENT,
                'password' => self::REPLACEMENT,
                'password_confirmation' => self::REPLACEMENT,
            ])
            ->assertRedirect('/login');

        $this->assertSame(self::CURRENT, $this->storedPassword());
    }

    /**
     * The middleware cannot catch this one. IsActive is a varchar holding the
     * STRING 'FALSE' in production, and (bool) 'FALSE' is true in PHP — the
     * defect in passwordreset.md §13 — so a directory-deactivated user sails
     * past active.user. The service reads the flag with FILTER_VALIDATE_BOOLEAN
     * and is currently the only thing on this path that gets it right.
     */
    public function test_a_directory_deactivated_user_is_refused_despite_the_string_false(): void
    {
        $this->actingAsDirectoryUser();

        DB::connection('SWRHAExpenseControl')->table('0006AWebAppControls')
            ->where('UserName', 'FFIGUERA1')
            ->update(['IsActive' => 'FALSE']);

        $this->change()->assertSessionHasErrors('current_password');

        $this->assertSame(self::CURRENT, $this->storedPassword());
    }

    public function test_a_user_cannot_touch_another_users_row(): void
    {
        $this->actingAsDirectoryUser();

        $otherLine = $this->directoryControlRow([
            'UserName' => 'KCHARLES1',
            'UserPassword' => 'someone-elses',
            'EmployeeID' => '200978',
        ]);

        $this->change();

        $this->assertSame(
            'someone-elses',
            $this->directoryControlRowWhere(['LineID' => $otherLine])->UserPassword
        );
    }

    public function test_the_kill_switch_disables_the_route_and_the_card(): void
    {
        $this->actingAsDirectoryUser();
        config(['auth.directory_password_change' => false]);

        $this->change()->assertSessionHasErrors('current_password');
        $this->assertSame(self::CURRENT, $this->storedPassword());

        $this->get('/profile')->assertInertia(
            fn (AssertableInertia $page) => $page->where('canChangePassword', false)
        );
    }

    public function test_it_is_throttled_with_a_flash_rather_than_a_429_error_page(): void
    {
        $this->actingAsDirectoryUser();

        for ($i = 0; $i < 6; $i++) {
            $this->change(['current_password' => 'wrong']);
        }

        // A 429 would render the full-page Error component and discard the
        // form; the limiter's response() callback is what keeps it a redirect.
        //
        // assertSessionHasNoErrors() is the load-bearing half for the UI: with
        // no validation errors, Inertia treats this as a completed visit and
        // fires onSuccess, not onError. PasswordChangeModal therefore checks
        // the error FLASH before closing, so a throttled attempt keeps the
        // dialog — and what the user typed — rather than discarding both.
        $this->change(['current_password' => 'wrong'])
            ->assertStatus(302)
            ->assertSessionHas('error')
            ->assertSessionHasNoErrors();
    }
}
