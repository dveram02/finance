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

    /**
     * Both pages, with their URL, Inertia component, status set and the LEDGER
     * COLUMN each one drills into.
     *
     * The last of those is what makes the all-years reconciliation assertion
     * route-specific: Encumbered's lines must sum to the summary's Approved,
     * Routing's to its Routing. Same money, two grains — the equality Phase 2's
     * gate enforces in SQL.
     */
    public static function pages(): array
    {
        return [
            'encumbered' => ['/encumbered-details', 'Expenditure/Encumbered Details', FinanceRequisition::APPROVED_STATUSES, 'Approved'],
            'routing' => ['/routing-details', 'Expenditure/Routing Details', FinanceRequisition::ROUTING_STATUSES, 'Routing'],
        ];
    }

    /** Every prop both pages must send, on the success path AND the outage path. */
    private const PROPS = [
        'rows', 'clusters', 'institutions', 'departments', 'accounts', 'vendors',
        'statuses', 'years', 'totals', 'filters', 'activeFiscalYear',
        'currentFiscalYear', 'hasAccess', 'snapshot', 'unsummarisedYears',
        // The bounded-fetch guard (routingupdate.md §6). BOTH, on every path:
        // naming only the first would give a 16-prop outage response against a
        // 17-prop success one and fail the parity assertion for an
        // uninteresting reason.
        'scopeRefused', 'scopeRefusedMessage',
    ];
    // No 'fyNav'. As of 2026-10-02 these two pages DO wear the FiscalYearHero
    // banner, but display-only: `:controls="false"`, so no year rail and no
    // prev/next stepper, and `all-years-label` lets it state the all-years scope
    // without a numeral. The year is an OPTIONAL select in their Filters card,
    // defaulting to All Fiscal Years, so there is still nothing for prev/next to
    // drive. The four summary pages pass fyNav and keep the full control, and
    // ResolvesFiscalYear::fiscalYearNav() is still theirs alone.

    /**
     * The row count the detail view holds for this user and status set,
     * restricted to a given year list. The independent half of every
     * all-years assertion below — computed from SQL, never from the page.
     *
     * @param  array<int,string>  $statuses
     * @param  array<int,string>|null  $years  null = every year, i.e. UNBOUNDED
     */
    private function detailCount(string $username, array $statuses, ?array $years = null): int
    {
        $query = DB::connection('FinanceAutomationSystem')
            ->table('vw_FinanceRequisitionDetail')
            ->where('UserName', $username)
            ->whereIn('Status', $statuses);

        if ($years !== null) {
            $query->whereIn('FinancialYear', $years);
        }

        return (int) $query->count();
    }

    #[DataProvider('pages')]
    public function test_the_page_renders_with_the_full_prop_shape(string $url, string $component, array $statuses, string $ledgerColumn): void
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
    public function test_every_row_carries_only_this_pages_statuses(string $url, string $component, array $statuses, string $ledgerColumn): void
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
     * The fiscal-year DROPDOWN must not offer a year the ledger has never built.
     *
     * Measured on production 2026-08-27, the requisition snapshot holds
     * FY2010-FY2026 while the ledger holds FY2014-FY2026. Offering FY2010-2013
     * would let a user drill into detail that reconciles against nothing.
     *
     * `years` feeds the select in the Filters card; it used to feed the hero's
     * year rail. Same prop, same bound, different control.
     */
    #[DataProvider('pages')]
    public function test_the_fiscal_year_dropdown_is_bounded_to_years_the_ledger_has(string $url, string $component, array $statuses, string $ledgerColumn): void
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
            $this->markTestSkipped("{$user->username} has no ledger rows to bound the dropdown against.");
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
    public function test_totals_cover_the_whole_filtered_set_not_the_visible_page(string $url, string $component, array $statuses, string $ledgerColumn): void
    {
        $user = $this->requisitionUser();

        $response = $this->actingAs($user)->get($url)->assertOk();
        $props = $response->viewData('page')['props'];

        if ($props['rows']['total'] <= count($props['rows']['data'])) {
            $this->markTestSkipped('Premise failed: this user has only one page of rows, so the two cannot differ.');
        }

        $this->assertSame($props['rows']['total'], $props['totals']['lines']);

        // NOT assertGreaterThan($visiblePageSum, …). ExtendedCost is signed
        // since the Access-parity change — 16 negative lines were in scope when
        // measured 2026-10-01 — so the whole-set total can legitimately be
        // SMALLER than one page's. The sound test is an exact independent sum
        // over the same scope the page reports.
        $years = array_map('strval', $props['years']);

        $expected = (float) DB::connection('FinanceAutomationSystem')
            ->table('vw_FinanceRequisitionDetail')
            ->where('UserName', $user->username)
            ->whereIn('Status', $statuses)
            ->whereIn('FinancialYear', $years)
            ->sum('ExtendedCost');

        $this->assertSame(
            round($expected, 2),
            round((float) $props['totals']['committed'], 2),
            'The totals row does not cover the whole filtered set.'
        );
    }

    #[DataProvider('pages')]
    public function test_a_filter_narrows_the_result_set(string $url, string $component, array $statuses, string $ledgerColumn): void
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

    /**
     * The year select posts ?fy=, so these assert the SERVER half of the control.
     *
     * Since 2026-10-01 the year is OPTIONAL: no ?fy= means every eligible year,
     * and `fy` goes through validFilter() like any other filter rather than
     * through resolveFiscalYear(), which can never return null.
     */
    #[DataProvider('pages')]
    public function test_the_fy_parameter_selects_that_year(string $url, string $component, array $statuses, string $ledgerColumn): void
    {
        $user = $this->requisitionUser();

        $props = $this->actingAs($user)->get($url)->assertOk()->viewData('page')['props'];

        if ($props['years'] === []) {
            $this->markTestSkipped('Premise failed: no selectable years.');
        }

        // The default is now NULL (all eligible years), so there is no
        // "resolved year" to pick something other than. Take the first option —
        // which is the NEWEST, since availableYears() reverses the ascending
        // source order.
        $year = (string) $props['years'][0];
        $this->assertNull($props['activeFiscalYear'], 'The default must be All, not a year.');

        $switched = $this->actingAs($user)->get($url.'?fy='.$year)->assertOk()->viewData('page')['props'];

        $this->assertSame((int) $year, (int) $switched['activeFiscalYear']);
        $this->assertSame((int) $year, (int) $switched['filters']['fy']);

        // And every row really carries it — the scope is bound in the query.
        foreach ($switched['rows']['data'] as $row) {
            $this->assertSame($year, (string) $row['FinancialYear']);
        }
    }

    /**
     * An out-of-range or malformed year must be DROPPED to All Fiscal Years —
     * never 500, and never an empty page that reads as missing data.
     *
     * This is a behaviour change: while the year was required it fell back to a
     * concrete year. It now goes through validFilter() like every other filter,
     * so a NON-EMPTY invalid value is also recorded in droppedFilters — which
     * the screen ignores and the EXPORT refuses on. That asymmetry is
     * deliberate and is covered in CsvExportTest.
     */
    #[DataProvider('pages')]
    public function test_an_unusable_fy_is_dropped_to_all_years(string $url, string $component, array $statuses, string $ledgerColumn): void
    {
        $user = $this->requisitionUser();

        $baseline = $this->actingAs($user)->get($url)->assertOk()->viewData('page')['props'];

        foreach (['9999', 'abc', '20261', '', '0'] as $bad) {
            $props = $this->actingAs($user)->get($url.'?fy='.$bad)->assertOk()->viewData('page')['props'];

            $this->assertNull($props['activeFiscalYear'],
                "?fy={$bad} should have been dropped to All Fiscal Years.");
            $this->assertNull($props['filters']['fy'],
                "?fy={$bad} should not be echoed back to the page.");

            // And it shows the SAME scope as no parameter at all — not an
            // empty table, which would read as missing data.
            $this->assertSame(
                $baseline['rows']['total'],
                $props['rows']['total'],
                "?fy={$bad} narrowed the scope instead of being dropped."
            );
        }
    }

    // =========================================================================
    // All Fiscal Years — the default scope since 2026-10-01
    // =========================================================================

    #[DataProvider('pages')]
    public function test_no_fy_parameter_covers_every_eligible_year(string $url, string $component, array $statuses, string $ledgerColumn): void
    {
        $user = $this->requisitionUser();

        $props = $this->actingAs($user)->get($url)->assertOk()->viewData('page')['props'];

        if ($props['years'] === []) {
            $this->markTestSkipped("{$user->username} has no eligible fiscal years on {$url}.");
        }

        $this->assertNull($props['activeFiscalYear']);

        // Computed from SQL over props['years'], not from the page's own count.
        $this->assertSame(
            $this->detailCount($user->username, $statuses, array_map('strval', $props['years'])),
            (int) $props['rows']['total'],
        );
    }

    /**
     * 🔴 THE R1-A REGRESSION TEST.
     *
     * "All" must mean every ELIGIBLE year — the ones this route's detail shares
     * with the ledger — never every year the snapshot holds. The withheld years
     * have no summary row to reconcile against, so including them silently
     * breaks the one invariant Phase 2 exists to protect. Measured 2026-10-01,
     * the unbounded query leaked 49 rows / TTD 75,829.66 on Encumbered.
     *
     * ASSERTED UNPAGINATED, deliberately. An earlier draft inspected
     * rows.data — page 1 — and with FinancialYear DESC the unsummarised years
     * sort LAST, so they could never have appeared there and the test would
     * have passed over the bug.
     */
    #[DataProvider('pages')]
    public function test_all_years_never_includes_an_unsummarised_year(string $url, string $component, array $statuses, string $ledgerColumn): void
    {
        $user = $this->requisitionUser();

        $props = $this->actingAs($user)->get($url)->assertOk()->viewData('page')['props'];

        if ($props['years'] === []) {
            $this->markTestSkipped("{$user->username} has no eligible fiscal years on {$url}.");
        }

        $eligible = $this->detailCount($user->username, $statuses, array_map('strval', $props['years']));
        $unbounded = $this->detailCount($user->username, $statuses);

        $this->assertSame($eligible, (int) $props['rows']['total']);

        if ($props['unsummarisedYears'] === []) {
            // Nothing is being withheld, so the two counts legitimately agree
            // and this case cannot distinguish the bug from correct behaviour.
            $this->assertSame($unbounded, $eligible);
            $this->markTestSkipped('Premise failed: no unsummarised years, so the bound cannot be observed.');
        }

        $this->assertLessThan($unbounded, (int) $props['rows']['total'],
            'The all-years scope is unbounded — it includes years the ledger has no summary for.');
    }

    /**
     * 🔴 R1-C — the all-years table must still tie to the summary.
     *
     * The detail is the SAME MONEY the ledger reports per account, at line
     * grain, and Phase 2's reconciliation gate enforces that in SQL. An
     * all-years view that did not reconcile would have broken the gate's
     * promise without the gate noticing.
     *
     * BOTH SIDES ARE BOUND TO props['years']. Measured 2026-10-01 the two also
     * agreed over the ledger's full 13-year boundary — but only because FY2022
     * and FY2023 ledger values happen to be zero, which is a coincidence of the
     * data and not a property of the code.
     */
    #[DataProvider('pages')]
    public function test_all_years_reconciles_to_the_ledger_across_the_eligible_set(string $url, string $component, array $statuses, string $ledgerColumn): void
    {
        $user = $this->requisitionUser();

        $props = $this->actingAs($user)->get($url)->assertOk()->viewData('page')['props'];

        if ($props['years'] === [] || (int) $props['rows']['total'] === 0) {
            $this->markTestSkipped("{$user->username} has no rows to reconcile on {$url}.");
        }

        $years = array_map('strval', $props['years']);

        $ledger = (float) DB::connection('FinanceAutomationSystem')
            ->table('vw_FinanceLedger')
            ->where('UserName', $user->username)
            ->whereIn('FinancialYear', $years)
            ->sum($ledgerColumn);

        $this->assertSame(
            round($ledger, 2),
            round((float) $props['totals']['committed'], 2),
            "The all-years detail does not tie to the summary's {$ledgerColumn} over the eligible years.",
        );
    }

    #[DataProvider('pages')]
    public function test_selecting_a_year_narrows_the_set(string $url, string $component, array $statuses, string $ledgerColumn): void
    {
        $user = $this->requisitionUser();

        $all = $this->actingAs($user)->get($url)->assertOk()->viewData('page')['props'];

        if (count($all['years']) < 2) {
            $this->markTestSkipped('Premise failed: fewer than two eligible years, so a year cannot narrow anything.');
        }

        $year = (string) $all['years'][0];
        $narrowed = $this->actingAs($user)->get($url.'?fy='.$year)->assertOk()->viewData('page')['props'];

        $this->assertLessThanOrEqual($all['rows']['total'], $narrowed['rows']['total']);
        $this->assertSame(
            $this->detailCount($user->username, $statuses, [$year]),
            (int) $narrowed['rows']['total'],
        );
    }

    /**
     * R2-1 — the eligible set is ROUTE-SPECIFIC, not the ledger's boundary.
     *
     * Measured 2026-10-01: Encumbered offers 11 years and Routing 3, against a
     * 13-year ledger boundary. Conflating the two is how a test ends up
     * asserting over the wrong set, so this binds the page's own options to a
     * query that uses that page's status set.
     */
    #[DataProvider('pages')]
    public function test_the_eligible_year_set_is_route_specific(string $url, string $component, array $statuses, string $ledgerColumn): void
    {
        $user = $this->requisitionUser();

        $props = $this->actingAs($user)->get($url)->assertOk()->viewData('page')['props'];

        $detailYears = DB::connection('FinanceAutomationSystem')
            ->table('vw_FinanceRequisitionDetail')
            ->where('UserName', $user->username)
            ->whereIn('Status', $statuses)          // THIS route's statuses
            ->distinct()
            ->pluck('FinancialYear')
            ->map(fn ($y) => (string) $y)
            ->all();

        $ledgerYears = DB::connection('FinanceAutomationSystem')
            ->table('vw_FinanceLedger')
            ->where('UserName', $user->username)
            ->distinct()
            ->pluck('FinancialYear')
            ->map(fn ($y) => (string) $y)
            ->all();

        $expected = array_values(array_intersect($detailYears, $ledgerYears));

        sort($expected);
        $actual = array_map('strval', $props['years']);
        sort($actual);

        $this->assertSame($expected, $actual,
            'The option list is not this route\'s detail years intersected with the ledger boundary.');
    }

    /**
     * R3-7 — newest first.
     *
     * availableYears() reads the source ascending and array_intersect preserves
     * that order, so without the reverse the dropdown read FY2014…FY2026 with
     * the most-wanted year LAST while the table read newest-first. It is also
     * what makes years[0] the newest, which the suggested-year redirect
     * depends on.
     */
    #[DataProvider('pages')]
    public function test_the_year_options_are_newest_first(string $url, string $component, array $statuses, string $ledgerColumn): void
    {
        $user = $this->requisitionUser();

        $props = $this->actingAs($user)->get($url)->assertOk()->viewData('page')['props'];

        if (count($props['years']) < 2) {
            $this->markTestSkipped('Premise failed: fewer than two years, so an order cannot be observed.');
        }

        $years = array_map('intval', $props['years']);
        $sorted = $years;
        rsort($sorted);

        $this->assertSame($sorted, $years);
    }

    #[DataProvider('pages')]
    public function test_the_rows_are_ordered_newest_fiscal_year_first(string $url, string $component, array $statuses, string $ledgerColumn): void
    {
        // FinancialYear DESC leads the sort so the years appear as CONTIGUOUS
        // BLOCKS rather than interleaved — paging through all-years is then a
        // walk backwards in time. Within one selected year the key is constant,
        // which is what keeps single-year output byte-identical to what it was
        // before the year became optional.
        $user = $this->requisitionUser();

        $props = $this->actingAs($user)->get($url)->assertOk()->viewData('page')['props'];
        $rows = $props['rows']['data'];

        if (count($rows) < 2) {
            $this->markTestSkipped('Premise failed: fewer than two rows on page 1.');
        }

        $previous = null;

        foreach ($rows as $row) {
            $year = (int) $row['FinancialYear'];

            if ($previous !== null) {
                $this->assertLessThanOrEqual($previous, $year,
                    'Fiscal years are not in descending order, so they are interleaved.');
            }

            $previous = $year;
        }
    }

    #[DataProvider('pages')]
    public function test_a_filter_value_that_is_not_an_option_is_ignored_rather_than_emptying_the_table(string $url, string $component, array $statuses, string $ledgerColumn): void
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
    public function test_the_snapshot_state_reaches_the_page_so_a_stale_build_can_alarm(string $url, string $component, array $statuses, string $ledgerColumn): void
    {
        // Phase 2 traded live data for reconciliation, and the page used to
        // carry a quiet "as at … rebuilt nightly, not live" line saying so. That
        // line was removed on 2026-10-02; SnapshotFreshness is now rendered
        // `faults-only`, so NOTHING is shown while the snapshot is healthy.
        //
        // That makes these props MORE load-bearing, not less: `state` is the
        // only thing that can still raise the amber strip, and it is the only
        // signal a user gets at all, because the production health-check task
        // has never been registered. Assert the whole shape the component reads.
        $this->actingAs($this->requisitionUser())
            ->get($url)
            ->assertOk()
            ->assertInertia(fn (AssertableInertia $page) => $page
                ->has('snapshot.refreshedAt')
                ->has('snapshot.age')
                ->has('snapshot.ageHours')
                ->has('snapshot.state')
                ->whereNot('snapshot.refreshedAt', null)
                // The four states are never conflated. A healthy build must not
                // report itself as one of the two that render amber.
                ->where('snapshot.state', fn ($state) => in_array($state, ['ok', 'stale', 'failed', 'unknown'], true))
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
    public function test_the_outage_path_renders_the_same_prop_shape_and_claims_no_knowledge_of_access(string $url, string $component, array $statuses, string $ledgerColumn): void
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
