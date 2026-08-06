<?php

namespace Tests\Feature;

use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\DB;
use Inertia\Testing\AssertableInertia;
use PHPUnit\Framework\Attributes\DataProvider;
use Tests\Feature\Concerns\UsesLedgerData;
use Tests\TestCase;

/**
 * "No departments are assigned to you" must be distinguishable from both
 * "the source is down" and "no rows matched your filters".
 *
 * These three states look identical in a table and mean entirely different
 * things: one is an outage to report, one is a permission to request, one is a
 * filter to change. Conflating them sends users to chase the wrong fix — which
 * is exactly what happened before `hasAccess` existed, when a user with no
 * mapping saw the dashboard claim the financial data source was unavailable.
 *
 * A factory user is, conveniently, a real zero-access user: the ledger is
 * scoped by UserName through vw_WebAppUserAccess, and a random username maps
 * to nothing.
 */
class LedgerAccessStateTest extends TestCase
{
    use RefreshDatabase;
    use UsesLedgerData;

    /** Every page that renders ledger-scoped data, with its Inertia component. */
    public static function ledgerPages(): array
    {
        return [
            'dashboard' => ['/dashboard', 'Dashboard'],
            'budget allocations' => ['/budget-allocations', 'Budget/All Budget Allocations'],
            'monthly expenditure' => ['/monthly-expenditure', 'Expenditure/Monthly Expenditure'],
            'department expenditure' => ['/department-expenditure', 'Expenditure/Department Expenditure'],
            'allocation line expenditure' => ['/allocation-line-expenditure', 'Expenditure/Allocation Line Expenditure'],
        ];
    }

    private function requireSqlServer(): void
    {
        try {
            DB::connection('FinanceAutomationSystem')->table('vw_WebAppUserAccess')->limit(1)->get();
        } catch (\Throwable $e) {
            $this->markTestSkipped('SQL Server is unavailable: '.$e->getMessage());
        }
    }

    #[DataProvider('ledgerPages')]
    public function test_a_user_with_no_department_mapping_is_told_so(string $url, string $component): void
    {
        $this->requireSqlServer();

        // Not a fixture: this username genuinely resolves to no departments.
        $user = User::factory()->create();

        $this->actingAs($user)
            ->get($url)
            ->assertOk()
            ->assertInertia(fn (AssertableInertia $page) => $page
                ->component($component)
                ->where('hasAccess', false)
            );
    }

    #[DataProvider('ledgerPages')]
    public function test_a_user_with_a_mapping_is_not_shown_the_no_access_state(string $url, string $component): void
    {
        $this->actingAs($this->ledgerUser())
            ->get($url)
            ->assertOk()
            ->assertInertia(fn (AssertableInertia $page) => $page
                ->component($component)
                ->where('hasAccess', true)
            );
    }

    /**
     * A user with no mapping does not make the expenditure query FAIL — the
     * access view is joined live, so it succeeds and simply returns no rows.
     * That leaves hasAccess false and expenditureAvailable TRUE at the same
     * time, which is the exact pairing the dashboard's expenditure KPI card
     * has to branch on in the right order: it used to test availability first,
     * making the "Not assigned" branch unreachable and printing a fabricated
     * TTD 0.00 to every unmapped user.
     *
     * The rendering is not assertable from here, but the prop combination is,
     * and pinning it stops a future reader concluding that "no access" implies
     * "unavailable" and collapsing those branches back together.
     */
    public function test_no_access_does_not_imply_the_expenditure_source_is_unavailable(): void
    {
        $this->requireSqlServer();

        $this->actingAs(User::factory()->create())
            ->get('/dashboard')
            ->assertOk()
            ->assertInertia(fn (AssertableInertia $page) => $page
                ->component('Dashboard')
                ->where('hasAccess', false)
                ->where('expenditureAvailable', true)
            );
    }

    public function test_the_no_access_state_does_not_flash_an_outage_warning(): void
    {
        $this->requireSqlServer();

        // The outage path flashes a warning; having no mapping is not an outage
        // and must not borrow its language.
        $this->actingAs(User::factory()->create())
            ->get('/department-expenditure')
            ->assertOk()
            ->assertSessionMissing('warning');
    }

    public function test_the_access_probe_is_scoped_to_the_signed_in_user(): void
    {
        $this->requireSqlServer();

        // Guards the cache key: a per-user answer cached under a shared key
        // would leak one user's access state to another.
        $ledgerUser = $this->ledgerUser();
        $strangerFirst = User::factory()->create();

        $this->actingAs($strangerFirst)->get('/dashboard')
            ->assertInertia(fn (AssertableInertia $page) => $page->where('hasAccess', false));

        $this->actingAs($ledgerUser)->get('/dashboard')
            ->assertInertia(fn (AssertableInertia $page) => $page->where('hasAccess', true));

        $this->actingAs($strangerFirst)->get('/dashboard')
            ->assertInertia(fn (AssertableInertia $page) => $page->where('hasAccess', false));
    }
}
