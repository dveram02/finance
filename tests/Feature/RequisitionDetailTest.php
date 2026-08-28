<?php

namespace Tests\Feature;

use App\Models\FinanceRequisition;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Inertia\Testing\AssertableInertia;
use PHPUnit\Framework\Attributes\DataProvider;
use Tests\Feature\Concerns\UsesRequisitionData;
use Tests\TestCase;

/**
 * The two Phase 3 requisition detail pages.
 *
 * These read dbo.vw_FinanceRequisitionDetail, so they need a reachable SQL
 * Server with the Phase 2 objects deployed AND a user with rows. There is none
 * in CI, so everything here SKIPS rather than fails when it cannot get data.
 * The arithmetic that can be tested offline lives in
 * Tests\Unit\DerivesRequisitionDetailTest.
 *
 * Assertions needing a particular data shape guard their premise and skip,
 * rather than assuming it and quietly passing over an empty set.
 */
class RequisitionDetailTest extends TestCase
{
    use RefreshDatabase;
    use UsesRequisitionData;

    /** Both pages, with their URL, Inertia component and status set. */
    public static function pages(): array
    {
        return [
            'encumbered' => ['/encumbered-details', 'Expenditure/Encumbered Details', FinanceRequisition::APPROVED_STATUSES],
            'routing' => ['/routing-details', 'Expenditure/Routing Details', FinanceRequisition::ROUTING_STATUSES],
        ];
    }

    /** Every prop both pages must send, on the success path AND the outage path. */
    private const PROPS = [
        'rows', 'clusters', 'institutions', 'departments', 'accounts', 'vendors',
        'statuses', 'years', 'totals', 'filters', 'activeFiscalYear',
        'currentFiscalYear', 'fyNav', 'hasAccess', 'snapshot', 'unsummarisedYears',
    ];

    #[DataProvider('pages')]
    public function test_the_page_renders_with_the_full_prop_shape(string $url, string $component, array $statuses): void
    {
        $this->actingAs($this->requisitionUser())
            ->get($url)
            ->assertOk()
            ->assertInertia(function (AssertableInertia $page) use ($component) {
                $page->component($component);

                foreach (self::PROPS as $prop) {
                    $page->has($prop);
                }
            });
    }

    #[DataProvider('pages')]
    public function test_every_row_carries_only_this_pages_statuses(string $url, string $component, array $statuses): void
    {
        $user = $this->requisitionUser();

        if ($this->requisitionFiscalYear($user->username, $statuses) === null) {
            $this->markTestSkipped("No {$component} rows for {$user->username}.");
        }

        $this->actingAs($user)
            ->get($url)
            ->assertOk()
            ->assertInertia(function (AssertableInertia $page) use ($statuses) {
                $rows = $page->toArray()['props']['rows']['data'];

                $this->assertNotEmpty($rows, 'Premise failed: the page returned no rows to check.');

                foreach ($rows as $row) {
                    $this->assertContains($row['Status'], $statuses);
                }
            });
    }

    /**
     * The rail must not offer a fiscal year the ledger has never built.
     *
     * Measured on production 2026-08-27, the requisition snapshot holds
     * FY2010-FY2026 while the ledger holds FY2014-FY2026. Offering FY2010-2013
     * would let a user drill into detail that reconciles against nothing.
     */
    #[DataProvider('pages')]
    public function test_the_fiscal_year_rail_is_bounded_to_years_the_ledger_has(string $url, string $component, array $statuses): void
    {
        $user = $this->requisitionUser();

        $ledgerYears = DB::connection('FinanceAutomationSystem')
            ->table('vw_FinanceLedger')
            ->where('UserName', $user->username)
            ->distinct()
            ->pluck('FinancialYear')
            ->map(fn ($y) => (string) $y)
            ->all();

        if ($ledgerYears === []) {
            $this->markTestSkipped("{$user->username} has no ledger rows to bound the rail against.");
        }

        $this->actingAs($user)
            ->get($url)
            ->assertOk()
            ->assertInertia(function (AssertableInertia $page) use ($ledgerYears) {
                $props = $page->toArray()['props'];

                foreach ($props['years'] as $year) {
                    $this->assertContains((string) $year, $ledgerYears,
                        "FY {$year} is offered but the ledger has no summary for it.");
                }

                // And whatever was withheld is named, not silently dropped.
                foreach ($props['unsummarisedYears'] as $year) {
                    $this->assertNotContains((string) $year, $ledgerYears);
                }
            });
    }

    #[DataProvider('pages')]
    public function test_totals_cover_the_whole_filtered_set_not_the_visible_page(string $url, string $component, array $statuses): void
    {
        $user = $this->requisitionUser();

        $response = $this->actingAs($user)->get($url)->assertOk();
        $props = $response->viewData('page')['props'];

        if ($props['rows']['total'] <= count($props['rows']['data'])) {
            $this->markTestSkipped('Premise failed: this user has only one page of rows, so the two cannot differ.');
        }

        $visible = array_sum(array_map(fn ($r) => (float) $r['ExtendedCost'], $props['rows']['data']));

        $this->assertSame($props['rows']['total'], $props['totals']['lines']);
        $this->assertGreaterThan($visible, $props['totals']['committed'],
            'The totals row is summing only the visible page.');
    }

    #[DataProvider('pages')]
    public function test_a_filter_narrows_the_result_set(string $url, string $component, array $statuses): void
    {
        $user = $this->requisitionUser();

        $unfiltered = $this->actingAs($user)->get($url)->assertOk()->viewData('page')['props'];

        if (count($unfiltered['departments']) < 2) {
            $this->markTestSkipped('Premise failed: fewer than two departments, so a filter cannot narrow anything.');
        }

        $filtered = $this->actingAs($user)
            ->get($url.'?department='.urlencode($unfiltered['departments'][0]))
            ->assertOk()
            ->viewData('page')['props'];

        $this->assertLessThan($unfiltered['rows']['total'], $filtered['rows']['total']);
        $this->assertSame($unfiltered['departments'][0], $filtered['filters']['department']);
    }

    #[DataProvider('pages')]
    public function test_a_filter_value_that_is_not_an_option_is_ignored_rather_than_emptying_the_table(string $url, string $component, array $statuses): void
    {
        // The failure mode this guards: a filter carried across a fiscal-year
        // switch silently empties the table and reads as missing data.
        $user = $this->requisitionUser();

        $unfiltered = $this->actingAs($user)->get($url)->assertOk()->viewData('page')['props'];
        $stale = $this->actingAs($user)
            ->get($url.'?department=A+DEPARTMENT+THAT+DOES+NOT+EXIST')
            ->assertOk()
            ->viewData('page')['props'];

        $this->assertNull($stale['filters']['department']);
        $this->assertSame($unfiltered['rows']['total'], $stale['rows']['total']);
    }

    #[DataProvider('pages')]
    public function test_the_page_says_when_the_snapshot_was_last_built(string $url, string $component, array $statuses): void
    {
        // Phase 2 traded live data for reconciliation. The trade is only honest
        // if the page says when the figures are from.
        $this->actingAs($this->requisitionUser())
            ->get($url)
            ->assertOk()
            ->assertInertia(fn (AssertableInertia $page) => $page
                ->has('snapshot.refreshedAt')
                ->has('snapshot.age')
                ->whereNot('snapshot.refreshedAt', null)
            );
    }

    /**
     * The outage path must render the SAME prop set as the success path.
     *
     * This bug class is invisible until SQL Server is actually down, at which
     * point a missing prop is a Vue error stacked on top of an outage. Forcing
     * the failure is the only way to see it before a user does.
     */
    #[DataProvider('pages')]
    public function test_the_outage_path_renders_the_same_prop_shape_and_claims_no_knowledge_of_access(string $url, string $component, array $statuses): void
    {
        $user = $this->requisitionUser();

        $healthy = array_keys($this->actingAs($user)->get($url)->assertOk()->viewData('page')['props']);

        // The filter lists, the access probe and the version stamp are all
        // cached on the file store, so a warm cache would serve the page
        // straight past the broken connection and prove nothing.
        Cache::store(config('ledger.cache.store'))->flush();

        // Port 1 on the loopback, with the shortest login timeout the driver
        // accepts: an outage, not a two-minute DNS wait. Without the timeout the
        // sqlsrv driver spends ~35s per attempt retrying.
        config([
            'database.connections.FinanceAutomationSystem.host' => '127.0.0.1',
            'database.connections.FinanceAutomationSystem.port' => '1',
            'database.connections.FinanceAutomationSystem.login_timeout' => 1,
        ]);
        DB::purge('FinanceAutomationSystem');

        $response = $this->actingAs($user)->get($url)->assertOk();
        $props = $response->viewData('page')['props'];

        $this->assertSame($healthy, array_keys($props));
        $this->assertSame(0, $props['rows']['total']);
        $this->assertSame(0.0, $props['totals']['committed']);
        $this->assertSame([], $props['years']);
        // Not "you have no access" — the probe could not run, so we do not know,
        // and telling someone they lack permissions during an outage sends them
        // to chase the wrong fix.
        $this->assertTrue($props['hasAccess']);
        $response->assertSessionHas('warning');

        // Leave nothing poisoned for the next test.
        Cache::store(config('ledger.cache.store'))->flush();
    }
}
