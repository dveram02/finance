<?php

namespace Tests\Feature;

use App\Models\FinanceRequisition;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;
use Mockery;
use PHPUnit\Framework\Attributes\DataProvider;
use Tests\Feature\Concerns\UsesRequisitionData;
use Tests\TestCase;

/**
 * The bounded-fetch guard, end to end — the SQL-backed half.
 *
 * The pure decisions (the redirect predicate and threshold normalisation) are
 * covered OFFLINE in Tests\Unit\RequisitionScopeDecisionTest. What is here is
 * what only a real query can show: that the LIMIT is actually applied, that the
 * redirect resolves, and that the refusal state carries the right props.
 *
 * THRESHOLDS ARE COMPUTED PER ROUTE AT RUNTIME, never hard-coded: Encumbered
 * has 11 eligible years to Routing's 3, and the data grows. Each case derives a
 * ceiling from that route's own all-years and newest-year counts, so the cases
 * keep meaning what they say.
 *
 * ⚠️ These assert the SERVER CONTRACT only. This app has no Inertia SSR — a
 * page response is `<div id="app" data-page="{json}">` with no Vue markup — so
 * an assertDontSee('TTD 0') here would pass VACUOUSLY and hand back a green
 * tick for an unverified rule. The DOM-level checks (the KPI grid absent, the
 * six selects disabled, no fake zero) are manual; see routingupdate.md §9.4.1.
 *
 * See routingupdate.md §6 and §9.2.
 */
class RequisitionScopeCeilingTest extends TestCase
{
    use RefreshDatabase;
    use UsesRequisitionData;

    /** Both pages, with their URL and status set. */
    public static function pages(): array
    {
        return [
            'encumbered' => ['/encumbered-details', FinanceRequisition::APPROVED_STATUSES],
            'routing' => ['/routing-details', FinanceRequisition::ROUTING_STATUSES],
        ];
    }

    /** Every prop both pages must send, on all three paths. 17 since the guard. */
    private const PROPS = [
        'rows', 'clusters', 'institutions', 'departments', 'accounts', 'vendors',
        'statuses', 'years', 'totals', 'filters', 'activeFiscalYear',
        'currentFiscalYear', 'hasAccess', 'snapshot', 'unsummarisedYears',
        'scopeRefused', 'scopeRefusedMessage',
    ];

    /**
     * Not this page's — HandleInertiaRequests::share() plus Inertia's own.
     * Named so the parity assertion can check the page's set EXACTLY rather
     * than counting, which would pass over a prop added to one path only.
     */
    private const SHARED_PROPS = ['auth', 'flash', 'appName', 'appVersion', 'errors', 'ziggy'];

    protected function setUp(): void
    {
        parent::setUp();

        // The filter lists, the access probe and the version stamp are all on
        // the file store, which survives RefreshDatabase. A warm entry from
        // another test (notably the outage parity case below) would serve a
        // page straight past whatever this one is trying to exercise.
        Cache::store(config('ledger.cache.store'))->flush();
    }

    /** Set the guard's thresholds for the request under test. */
    private function withThresholds(int $ceiling, int $warn = 0): void
    {
        config([
            'ledger.requisition.row_ceiling' => $ceiling,
            'ledger.requisition.row_warn' => $warn,
        ]);
    }

    /**
     * The props of one request, with the guard effectively off.
     *
     * @return array<string,mixed>
     */
    private function propsOf(User $user, string $url): array
    {
        return $this->actingAs($user)->get($url)->assertOk()->viewData('page')['props'];
    }

    /**
     * This route's all-years row count and its newest eligible year's count —
     * the two numbers every threshold here is derived from.
     *
     * @return array{all:int,newestYear:int,newest:string,years:array<int,string>}
     */
    private function scopeSizes(User $user, string $url): array
    {
        // A ceiling that cannot be reached, so these are true totals and not a
        // bounded fetch's truncation.
        $this->withThresholds(0);

        $all = $this->propsOf($user, $url);

        if ($all['years'] === []) {
            $this->markTestSkipped("{$user->username} has no eligible fiscal years on {$url}.");
        }

        // years arrives NEWEST FIRST, which is also what suggestedYear uses.
        $newest = (string) $all['years'][0];
        $year = $this->propsOf($user, $url.'?fy='.$newest);

        return [
            'all' => (int) $all['rows']['total'],
            'newestYear' => (int) $year['rows']['total'],
            'newest' => $newest,
            'years' => array_map('strval', $all['years']),
        ];
    }

    // =========================================================================
    // 1-2 · The guard is quiet when the scope fits
    // =========================================================================

    #[DataProvider('pages')]
    public function test_a_scope_within_the_ceiling_is_served_whole(string $url, array $statuses): void
    {
        $user = $this->requisitionUser();
        $sizes = $this->scopeSizes($user, $url);

        $this->withThresholds($sizes['all'] + 1000);
        $props = $this->propsOf($user, $url);

        $this->assertFalse($props['scopeRefused']);
        $this->assertNull($props['scopeRefusedMessage']);
        $this->assertNull($props['activeFiscalYear'], 'All should still be All.');
        $this->assertSame($sizes['all'], (int) $props['rows']['total']);
    }

    #[DataProvider('pages')]
    public function test_a_large_but_servable_scope_logs_exactly_one_warning(string $url, array $statuses): void
    {
        $user = $this->requisitionUser();
        $sizes = $this->scopeSizes($user, $url);

        if ($sizes['all'] < 2) {
            $this->markTestSkipped('Premise failed: fewer than two rows, so no warn threshold sits below the count.');
        }

        // Warn below the count, ceiling above it.
        $this->withThresholds($sizes['all'] + 1000, $sizes['all'] - 1);

        Log::spy();

        $props = $this->propsOf($user, $url);

        $this->assertFalse($props['scopeRefused'], 'A warning must not refuse.');

        // ONCE. resolve() holds the guard and index() calls it once — a second
        // call would mean the screen and the export had diverged into two query
        // paths, which is the thing resolve() exists to prevent.
        Log::shouldHaveReceived('warning')
            ->with('Requisition detail working set is large; see routingupdate.md §6.', Mockery::type('array'))
            ->once();
    }

    // =========================================================================
    // 3-6 · All-years over the ceiling redirects to the newest year
    // =========================================================================

    #[DataProvider('pages')]
    public function test_an_oversized_all_years_scope_redirects_to_the_newest_year(string $url, array $statuses): void
    {
        $user = $this->requisitionUser();
        $sizes = $this->scopeSizes($user, $url);

        if ($sizes['all'] <= $sizes['newestYear']) {
            $this->markTestSkipped('Premise failed: all-years is no larger than the newest year, so the two cannot be distinguished.');
        }

        // Below all-years, at or above the newest year — so the redirect target
        // itself renders.
        $this->withThresholds($sizes['newestYear']);

        $response = $this->actingAs($user)->get($url);

        $response->assertRedirect();
        $this->assertStringContainsString('fy='.$sizes['newest'], $response->headers->get('Location'));
        $response->assertSessionHas('warning');
    }

    #[DataProvider('pages')]
    public function test_the_redirect_target_renders_and_does_not_redirect_again(string $url, array $statuses): void
    {
        $user = $this->requisitionUser();
        $sizes = $this->scopeSizes($user, $url);

        if ($sizes['all'] <= $sizes['newestYear']) {
            $this->markTestSkipped('Premise failed: all-years is no larger than the newest year.');
        }

        $this->withThresholds($sizes['newestYear']);

        $props = $this->actingAs($user)
            ->get($url.'?fy='.$sizes['newest'])
            ->assertOk()                       // NOT a 302 — no loop
            ->viewData('page')['props'];

        $this->assertFalse($props['scopeRefused']);
        $this->assertSame((int) $sizes['newest'], (int) $props['activeFiscalYear']);
    }

    #[DataProvider('pages')]
    public function test_the_redirect_warning_names_a_real_year_and_never_the_placeholder(string $url, array $statuses): void
    {
        $user = $this->requisitionUser();
        $sizes = $this->scopeSizes($user, $url);

        if ($sizes['all'] <= $sizes['newestYear']) {
            $this->markTestSkipped('Premise failed: all-years is no larger than the newest year.');
        }

        $this->withThresholds($sizes['newestYear']);

        $this->actingAs($user)->get($url)->assertRedirect();

        $flash = session('warning');

        // The constant carries a :year placeholder. An earlier draft passed it
        // bare to ->with('warning', …), so users read a literal "FY :year".
        $this->assertStringNotContainsString(':year', $flash);
        $this->assertStringContainsString('FY '.$sizes['newest'], $flash);
    }

    #[DataProvider('pages')]
    public function test_a_requested_categorical_filter_is_carried_to_the_narrower_year(string $url, array $statuses): void
    {
        $user = $this->requisitionUser();
        $sizes = $this->scopeSizes($user, $url);

        if ($sizes['all'] <= $sizes['newestYear']) {
            $this->markTestSkipped('Premise failed: all-years is no larger than the newest year.');
        }

        $this->withThresholds(0);
        $departments = $this->propsOf($user, $url)['departments'];

        if ($departments === []) {
            $this->markTestSkipped('Premise failed: no department to carry.');
        }

        $this->withThresholds($sizes['newestYear']);

        $response = $this->actingAs($user)->get($url.'?department='.urlencode($departments[0]));

        $response->assertRedirect();
        $location = $response->headers->get('Location');

        $this->assertStringContainsString('department=', $location);
        $this->assertStringContainsString('fy='.$sizes['newest'], $location);

        // FOLLOW THE WHOLE CHAIN and assert the FINAL state. A single-hop
        // assertion is what would let a double redirect through: the requested
        // value is re-validated at the target year, where it is honoured if it
        // is an option there and dropped with the usual visible reset if not.
        $final = $this->actingAs($user)->get($location);
        $final->assertOk();

        $props = $final->viewData('page')['props'];
        $this->assertSame((int) $sizes['newest'], (int) $props['activeFiscalYear']);

        if (in_array($departments[0], $props['departments'], true)) {
            $this->assertSame($departments[0], $props['filters']['department']);
        } else {
            $this->assertNull($props['filters']['department'],
                'A value absent from the target year must be dropped there, not forced.');
        }
    }

    #[DataProvider('pages')]
    public function test_an_array_filter_is_not_propagated_through_the_redirect(string $url, array $statuses): void
    {
        $user = $this->requisitionUser();
        $sizes = $this->scopeSizes($user, $url);

        if ($sizes['all'] <= $sizes['newestYear']) {
            $this->markTestSkipped('Premise failed: all-years is no larger than the newest year.');
        }

        $this->withThresholds($sizes['newestYear']);

        $response = $this->actingAs($user)->get($url.'?department[]=x');

        $response->assertRedirect();
        $this->assertStringNotContainsString('department', $response->headers->get('Location'));
    }

    // =========================================================================
    // 7-10 · A SELECTED year over the ceiling has no redirect and no recovery
    // =========================================================================

    #[DataProvider('pages')]
    public function test_an_oversized_selected_year_is_refused_in_place(string $url, array $statuses): void
    {
        $user = $this->requisitionUser();
        $sizes = $this->scopeSizes($user, $url);

        if ($sizes['newestYear'] < 2) {
            $this->markTestSkipped('Premise failed: the newest year has fewer than two rows, so no ceiling sits below it.');
        }

        $this->withThresholds($sizes['newestYear'] - 1);

        $props = $this->actingAs($user)
            ->get($url.'?fy='.$sizes['newest'])
            ->assertOk()                       // NOT a 302 — redirecting here would loop
            ->viewData('page')['props'];

        $this->assertTrue($props['scopeRefused']);
        $this->assertSame((int) $sizes['newest'], (int) $props['activeFiscalYear']);
    }

    #[DataProvider('pages')]
    public function test_a_ceiling_below_the_fallback_year_too_does_not_loop(string $url, array $statuses): void
    {
        $user = $this->requisitionUser();
        $sizes = $this->scopeSizes($user, $url);

        if ($sizes['newestYear'] < 2) {
            $this->markTestSkipped('Premise failed: the newest year has fewer than two rows.');
        }

        // Below EVERY year, so the redirect target is itself over the ceiling.
        $this->withThresholds($sizes['newestYear'] - 1);

        // One hop to the suggested year, which then refuses rather than
        // bouncing again.
        $response = $this->actingAs($user)->get($url);
        $response->assertRedirect();

        $second = $this->actingAs($user)->get($response->headers->get('Location'));
        $second->assertOk();
        $this->assertTrue($second->viewData('page')['props']['scopeRefused']);
    }

    #[DataProvider('pages')]
    public function test_a_user_with_no_eligible_years_gets_no_rows_rather_than_every_row(string $url, array $statuses): void
    {
        // whereIn('FinancialYear', []) compiles to WHERE 0 = 1, which is the
        // correct answer: no eligible years means no eligible detail. This is
        // the one place "no filter" must NOT mean "everything" — and it is not
        // a refusal either, because zero rows exceeds no ceiling.
        $this->requisitionUser();        // skips if SQL Server is unreachable

        $stranger = User::factory()->create(['username' => 'NOBODY-'.uniqid()]);

        $this->withThresholds(25000);
        $props = $this->propsOf($stranger, $url);

        $this->assertSame([], $props['years']);
        $this->assertSame(0, (int) $props['rows']['total']);
        $this->assertFalse($props['scopeRefused']);
        $this->assertNull($props['activeFiscalYear']);
    }

    #[DataProvider('pages')]
    public function test_the_refusal_props_are_exactly_right(string $url, array $statuses): void
    {
        $user = $this->requisitionUser();
        $sizes = $this->scopeSizes($user, $url);

        if ($sizes['newestYear'] < 2) {
            $this->markTestSkipped('Premise failed: the newest year has fewer than two rows.');
        }

        $this->withThresholds($sizes['newestYear'] - 1);

        $props = $this->actingAs($user)
            ->get($url.'?fy='.$sizes['newest'])
            ->assertOk()
            ->viewData('page')['props'];

        $this->assertTrue($props['scopeRefused']);

        // The SINGLE-YEAR variant. Only this one is assertable over HTTP: the
        // all-years variant is unreachable, because all-years over the ceiling
        // redirects, and with no eligible years the scope is 0 rows and cannot
        // be refused. Its selection is a pure-function case in the unit suite.
        $this->assertStringContainsString('too many requisition lines to display or export', $props['scopeRefusedMessage']);

        // Never the truncated fetch — an arbitrary N of M rows measures nothing.
        $this->assertSame([], $props['rows']['data']);
        $this->assertSame(0, (int) $props['rows']['total']);

        // THE RECOVERY MUST BE REACHABLE. `years` comes from availableYears(),
        // not from the fetched rows, so the Fiscal Year dropdown is still
        // populated while every other option list is empty. Choosing a year is
        // the only recovery — categorical filters are applied in memory after
        // the bounded fetch and can never shrink it.
        $this->assertNotEmpty($props['years']);
        $this->assertSame([], $props['clusters']);
        $this->assertSame([], $props['departments']);

        // Structural padding for a table that renders nothing, identical to the
        // outage path's zeros. The component gates every quantity on
        // !scopeRefused, so these are never rendered — verified in a browser,
        // not here (routingupdate.md §9.4.1).
        $this->assertSame(0.0, $props['totals']['committed']);
        $this->assertSame(0, $props['totals']['lines']);
        $this->assertSame(0, $props['totals']['requisitions']);
    }

    // =========================================================================
    // 11 · The export refuses rather than truncating
    // =========================================================================

    #[DataProvider('pages')]
    public function test_the_export_refuses_an_oversized_selected_year_and_streams_nothing(string $url, array $statuses): void
    {
        $user = $this->requisitionUser();
        $sizes = $this->scopeSizes($user, $url);

        if ($sizes['newestYear'] < 2) {
            $this->markTestSkipped('Premise failed: the newest year has fewer than two rows.');
        }

        $this->withThresholds($sizes['newestYear'] - 1);

        $response = $this->actingAs($user)->get($url.'/export?fy='.$sizes['newest']);

        $response->assertRedirect();

        // THE SAME YEAR, never ?fy=0. suggestedYear is deliberately null here,
        // and a `?? 0` fallback would send the user to an invalid year that
        // validFilter() drops — so index() would read it as all-years and
        // redirect again, moving them off the year they asked about.
        $this->assertStringContainsString('fy='.$sizes['newest'], $response->headers->get('Location'));
        $this->assertStringNotContainsString('fy=0', $response->headers->get('Location'));

        // "No file was created" — the message must say that, because a refused
        // download is otherwise indistinguishable from a slow one.
        $this->assertStringContainsString('No file was created', session('warning'));

        $this->assertNotSame('text/csv', $response->headers->get('Content-Type'));
    }

    #[DataProvider('pages')]
    public function test_the_export_refuses_an_oversized_all_years_scope_and_lands_on_a_year(string $url, array $statuses): void
    {
        $user = $this->requisitionUser();
        $sizes = $this->scopeSizes($user, $url);

        if ($sizes['all'] <= $sizes['newestYear']) {
            $this->markTestSkipped('Premise failed: all-years is no larger than the newest year.');
        }

        $this->withThresholds($sizes['newestYear']);

        $response = $this->actingAs($user)->get($url.'/export');

        $response->assertRedirect();

        // STRAIGHT to the suggested year, in ONE hop. exportRedirect() replays
        // the query string, which on this path would hand index() a yearless
        // URL, earn a SECOND redirect, and leave the final flash describing
        // display selection without ever saying no file was produced.
        $location = $response->headers->get('Location');
        $this->assertStringContainsString('fy='.$sizes['newest'], $location);
        $this->assertStringContainsString('No file was created', session('warning'));
        $this->assertStringNotContainsString(':year', session('warning'));

        $this->actingAs($user)->get($location)->assertOk();     // no second redirect
        $this->assertNotSame('text/csv', $response->headers->get('Content-Type'));
    }

    // =========================================================================
    // 12 · Final-prop parity across all three paths
    // =========================================================================

    #[DataProvider('pages')]
    public function test_all_three_paths_send_an_identical_prop_set(string $url, array $statuses): void
    {
        // A prop one path omits is a Vue error stacked on top of whatever else
        // went wrong, and it is invisible until that path is actually taken.
        $user = $this->requisitionUser();
        $sizes = $this->scopeSizes($user, $url);

        if ($sizes['newestYear'] < 2) {
            $this->markTestSkipped('Premise failed: the newest year has fewer than two rows, so the refusal path is unreachable.');
        }

        $this->withThresholds($sizes['all'] + 1000);
        $success = array_keys($this->propsOf($user, $url));

        $this->withThresholds($sizes['newestYear'] - 1);
        $refused = array_keys($this->propsOf($user, $url.'?fy='.$sizes['newest']));

        $this->assertSame($success, $refused);

        // Exactly PROPS, once the globals from HandleInertiaRequests and
        // Inertia's own are set aside. Asserting the exact set rather than a
        // count is what catches a prop quietly added to one path only.
        $this->assertSame(
            self::PROPS,
            array_values(array_diff($success, self::SHARED_PROPS)),
            'The page prop set has drifted from the declared contract.',
        );

        // ── And the outage path ─────────────────────────────────────────────
        Cache::store(config('ledger.cache.store'))->flush();

        config([
            'database.connections.FinanceAutomationSystem.host' => '127.0.0.1',
            'database.connections.FinanceAutomationSystem.port' => '1',
            'database.connections.FinanceAutomationSystem.login_timeout' => 1,
        ]);
        DB::purge('FinanceAutomationSystem');

        $outage = $this->actingAs($user)->get($url)->assertOk()->viewData('page')['props'];

        $this->assertSame($success, array_keys($outage));
        // Nothing was refused — the source was unreachable, which is a
        // different state with its own copy.
        $this->assertFalse($outage['scopeRefused']);
        $this->assertNull($outage['scopeRefusedMessage']);
        // And the year falls back to ALL, not to the requested value: the
        // eligible set is unknown, so no year can be validated against it.
        $this->assertNull($outage['activeFiscalYear']);

        Cache::store(config('ledger.cache.store'))->flush();
    }

    #[DataProvider('pages')]
    public function test_the_outage_path_falls_back_to_all_years_not_a_four_digit_guess(string $url, array $statuses): void
    {
        $user = $this->requisitionUser();

        Cache::store(config('ledger.cache.store'))->flush();

        config([
            'database.connections.FinanceAutomationSystem.host' => '127.0.0.1',
            'database.connections.FinanceAutomationSystem.port' => '1',
            'database.connections.FinanceAutomationSystem.login_timeout' => 1,
        ]);
        DB::purge('FinanceAutomationSystem');

        // ?fy=9999 must not be echoed back: the page would paint
        // "FY 9999 · Oct 9998 – Sep 9999" over an empty table during an outage.
        $props = $this->actingAs($user)->get($url.'?fy=9999')->assertOk()->viewData('page')['props'];

        $this->assertNull($props['activeFiscalYear']);
        $this->assertNull($props['filters']['fy']);

        Cache::store(config('ledger.cache.store'))->flush();
    }
}
