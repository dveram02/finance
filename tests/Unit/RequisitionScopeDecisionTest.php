<?php

namespace Tests\Unit;

use App\Http\Controllers\RequisitionDetailController;
use App\Support\RequisitionScopeThresholds;
use Illuminate\Support\Carbon;
use PHPUnit\Framework\TestCase;

/**
 * The bounded-fetch guard's two pure parts — OFFLINE, so these always run.
 *
 * The guard is the most safety-critical code the fiscal-year change adds, and
 * putting every case behind SQL Server would mean it SKIPS on any machine
 * without one: exactly the hazard that made DerivesRequisitionDetail a DB-free
 * trait. The query integration is covered separately in
 * Tests\Feature\RequisitionScopeCeilingTest, which does skip.
 *
 * See routingupdate.md §6.5 and §9.2.
 */
class RequisitionScopeDecisionTest extends TestCase
{
    /**
     * A concrete subclass, for the one protected decision method. The parent is
     * abstract on three things and nothing here touches the container, the
     * database or a request.
     */
    private function controller(): RequisitionDetailController
    {
        return new class extends RequisitionDetailController
        {
            protected function statuses(): array
            {
                return ['AP', 'PO'];
            }

            protected function component(): string
            {
                return 'Expenditure/Encumbered Details';
            }

            protected function routeName(): string
            {
                return 'encumbered-details.index';
            }

            /** @param array<string,mixed> $r */
            public function decide(array $r): bool
            {
                return $this->shouldRedirectToSuggestedYear($r);
            }

            public function state(?string $refreshedAt, ?string $latestOutcome, int $maxAgeHours = 36): string
            {
                return $this->snapshotState($refreshedAt, $latestOutcome, $maxAgeHours);
            }
        };
    }

    /** @return array<string,mixed> */
    private function resolution(array $overrides = []): array
    {
        return array_merge([
            'scopeRefused' => false,
            'activeFiscalYear' => null,
            'suggestedYear' => null,
        ], $overrides);
    }

    // =========================================================================
    // shouldRedirectToSuggestedYear() — four cases, three of which must NOT
    // redirect. Only the all-years-with-a-fallback case does.
    // =========================================================================

    public function test_an_oversized_all_years_scope_redirects_to_the_suggested_year(): void
    {
        $this->assertTrue($this->controller()->decide($this->resolution([
            'scopeRefused' => true,
            'activeFiscalYear' => null,
            'suggestedYear' => 2026,
        ])));
    }

    public function test_an_oversized_selected_year_does_not_redirect(): void
    {
        // It would be a loop: the target of the redirect IS the year that was
        // refused. suggestedYear is null precisely to stop this, and the page
        // shows the single-year refusal copy instead.
        $this->assertFalse($this->controller()->decide($this->resolution([
            'scopeRefused' => true,
            'activeFiscalYear' => 2026,
            'suggestedYear' => null,
        ])));
    }

    public function test_a_refusal_with_no_eligible_year_does_not_redirect(): void
    {
        // There is nowhere to go. ?fy=0 would be the alternative, which
        // validFilter() drops — so index() would read it as all-years and
        // redirect again.
        $this->assertFalse($this->controller()->decide($this->resolution([
            'scopeRefused' => true,
            'activeFiscalYear' => null,
            'suggestedYear' => null,
        ])));
    }

    public function test_a_resolved_scope_never_redirects(): void
    {
        $this->assertFalse($this->controller()->decide($this->resolution([
            'scopeRefused' => false,
            'activeFiscalYear' => null,
            'suggestedYear' => 2026,
        ])));
    }

    // =========================================================================
    // RequisitionScopeThresholds — the normalisation MUST FAIL CLOSED.
    //
    // The hazard these guard: 0 is the explicit opt-out, and almost every
    // malformed value truncates to 0 under (int). A normaliser that cast first
    // would read an .env typo as "deliberately disable the memory guard".
    // =========================================================================

    public function test_a_normal_configuration_is_passed_through(): void
    {
        $t = RequisitionScopeThresholds::fromConfig(25000, 20000);

        $this->assertSame(25000, $t->ceiling);
        $this->assertSame(20000, $t->warnAt);
    }

    public function test_an_explicit_zero_disables_the_guard_and_the_warnings_too(): void
    {
        // Stated, not implied: with no ceiling there is no scale to warn
        // against, and a warning that fires on every request is noise.
        foreach ([0, '0'] as $value) {
            $t = RequisitionScopeThresholds::fromConfig($value, 20000);

            $this->assertSame(0, $t->ceiling, 'ceiling for '.var_export($value, true));
            $this->assertSame(0, $t->warnAt, 'warnAt for '.var_export($value, true));
        }
    }

    public function test_a_warn_at_or_above_the_ceiling_is_clamped_rather_than_left_dead(): void
    {
        // The ceiling refuses first, so such a warn could never fire.
        foreach ([25000, 30000] as $warn) {
            $this->assertSame(20000, RequisitionScopeThresholds::fromConfig(25000, $warn)->warnAt);
        }
    }

    public function test_a_negative_ceiling_falls_back_to_the_default_not_to_unbounded(): void
    {
        // The defect this exists for: max(0, -1) is 0, and 0 means UNBOUNDED.
        $this->assertSame(
            RequisitionScopeThresholds::DEFAULT_CEILING,
            RequisitionScopeThresholds::fromConfig(-1, 20000)->ceiling,
        );
    }

    public function test_a_non_numeric_ceiling_falls_back_to_the_default(): void
    {
        foreach (['abc', null, [], true, 1.5] as $value) {
            $this->assertSame(
                RequisitionScopeThresholds::DEFAULT_CEILING,
                RequisitionScopeThresholds::fromConfig($value, 20000)->ceiling,
                'ceiling for '.var_export($value, true),
            );
        }
    }

    public function test_php_int_max_is_clamped_so_ceiling_plus_one_cannot_overflow(): void
    {
        $t = RequisitionScopeThresholds::fromConfig(PHP_INT_MAX, 20000);

        $this->assertSame(RequisitionScopeThresholds::MAX_CEILING, $t->ceiling);
        $this->assertGreaterThan($t->ceiling, $t->ceiling + 1);
    }

    public function test_anything_above_the_hard_maximum_is_clamped_to_it(): void
    {
        foreach ([100000, '100000'] as $value) {
            $this->assertSame(
                RequisitionScopeThresholds::MAX_CEILING,
                RequisitionScopeThresholds::fromConfig($value, 20000)->ceiling,
                'ceiling for '.var_export($value, true),
            );
        }
    }

    public function test_a_negative_warn_is_zero_never_negative(): void
    {
        $this->assertSame(0, RequisitionScopeThresholds::fromConfig(25000, -5)->warnAt);
        $this->assertSame(0, RequisitionScopeThresholds::fromConfig(25000, 'abc')->warnAt);
    }

    /**
     * The heart of it. Every value below truncates to 0 under (int), so a
     * normaliser built on is_numeric() + a cast would read each one as the
     * opt-out and silently remove the guard. The strict parser is what
     * separates "nonsense, use the default" from "deliberately disabled".
     */
    public function test_values_that_truncate_to_zero_are_nonsense_not_an_opt_out(): void
    {
        foreach (['0.5', '-0.5', '00', '000', '1e5', '1e-9', '', ' ', 'O'] as $value) {
            $this->assertSame(
                RequisitionScopeThresholds::DEFAULT_CEILING,
                RequisitionScopeThresholds::fromConfig($value, 20000)->ceiling,
                "'{$value}' must default, never disable the guard",
            );
        }
    }

    public function test_a_signed_string_is_not_accepted(): void
    {
        // ^\d+$ has no sign branch. '-25000' must not become 25000, and
        // '+25000' is a typo rather than an intention worth honouring.
        foreach (['+25000', '-25000'] as $value) {
            $this->assertSame(
                RequisitionScopeThresholds::DEFAULT_CEILING,
                RequisitionScopeThresholds::fromConfig($value, 20000)->ceiling,
                "'{$value}' must default",
            );
        }
    }

    public function test_surrounding_whitespace_is_trimmed_on_purpose(): void
    {
        // A realistic .env typo, and harmless — unlike an internal space.
        $this->assertSame(25000, RequisitionScopeThresholds::fromConfig(' 25000 ', ' 20000 ')->ceiling);
        $this->assertSame(20000, RequisitionScopeThresholds::fromConfig(' 25000 ', ' 20000 ')->warnAt);

        $this->assertSame(
            RequisitionScopeThresholds::DEFAULT_CEILING,
            RequisitionScopeThresholds::fromConfig('25 000', 20000)->ceiling,
        );
    }

    public function test_the_shipped_default_matches_the_config_file(): void
    {
        // If these drift, the fail-closed fallback stops being the configured
        // value and starts being a surprise.
        $this->assertSame(25000, RequisitionScopeThresholds::DEFAULT_CEILING);
        $this->assertLessThan(RequisitionScopeThresholds::MAX_CEILING, RequisitionScopeThresholds::DEFAULT_CEILING);
    }

    // =========================================================================
    // snapshotState() — the four snapshot states
    //
    // A stopped Agent job produces NO error of any kind: pages keep loading
    // fast and the figures simply stop moving. With no monitoring configured on
    // production, the context strip is currently the only place a user could
    // notice, so the judgement behind it is worth pinning offline.
    // =========================================================================

    protected function setUp(): void
    {
        parent::setUp();

        // Fixed "now", so the age boundaries below are exact rather than
        // relative to the day the suite happens to run. snapshotState() takes
        // the threshold as an argument precisely so no container is needed here.
        Carbon::setTestNow(Carbon::parse('2026-10-02 09:00:00'));
    }

    protected function tearDown(): void
    {
        Carbon::setTestNow();

        parent::tearDown();
    }

    public function test_a_snapshot_built_last_night_is_ok_not_a_fault(): void
    {
        // Being a night old is the DESIGNED state. Amber here would train
        // people to ignore amber everywhere else.
        $this->assertSame('ok', $this->controller()->state('2026-10-01 21:35:00', 'OK'));
    }

    public function test_an_unreadable_probe_is_unknown_never_stale(): void
    {
        // We do not know. Telling someone the nightly job has failed when the
        // metadata query merely timed out sends them to chase the wrong thing —
        // the same rule the outage path's hasAccess => true follows.
        $this->assertSame('unknown', $this->controller()->state(null, null));
        $this->assertSame('unknown', $this->controller()->state(null, 'ABORTED'));
    }

    public function test_a_build_older_than_the_limit_is_stale(): void
    {
        // 36h limit, job runs daily at 21:30 — so past 36h at least one
        // nightly run was missed.
        $this->assertSame('stale', $this->controller()->state('2026-09-29 21:35:00', 'OK'));
    }

    public function test_the_limit_is_an_upper_bound_not_an_inclusive_one(): void
    {
        // Just inside 36h must stay quiet; just outside must not.
        $this->assertSame('ok', $this->controller()->state('2026-09-30 22:00:00', 'OK'));
        $this->assertSame('stale', $this->controller()->state('2026-09-30 20:00:00', 'OK'));
    }

    public function test_an_aborted_newest_run_is_failed_even_while_the_timestamp_is_fresh(): void
    {
        // THE CASE THE TIMESTAMP CANNOT SEE. The log is run-keyed, so an
        // aborted run appends an ABORTED row while the previous snapshot
        // stands — completely invisible to MAX(RefreshedAt) WHERE Outcome = OK.
        $this->assertSame('failed', $this->controller()->state('2026-10-01 21:35:00', 'ABORTED'));
    }

    public function test_failed_wins_over_stale_because_it_is_more_actionable(): void
    {
        // A run that aborted tonight is not yet 36h stale; reporting only the
        // age would hide it until tomorrow.
        $this->assertSame('failed', $this->controller()->state('2026-09-28 21:35:00', 'ABORTED'));
    }

    public function test_the_outcome_comparison_is_case_insensitive(): void
    {
        $this->assertSame('ok', $this->controller()->state('2026-10-01 21:35:00', 'ok'));
        $this->assertSame('failed', $this->controller()->state('2026-10-01 21:35:00', 'aborted'));
    }
}
