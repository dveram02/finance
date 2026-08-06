<?php

namespace Tests\Feature;

use App\Http\Middleware\EnsureUserIsActive;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Inertia\Testing\AssertableInertia;
use PHPUnit\Framework\Attributes\DataProvider;
use Tests\Feature\Concerns\UsesBudgetData;
use Tests\TestCase;

/**
 * Fiscal-year navigation on the dashboard.
 *
 * The year rail is scoped to years with BUDGET data, not every year with
 * expenditure — this page is budget-vs-actual, so a year with spend but no
 * allocation baseline has nothing to compare against. Hence UsesBudgetData
 * rather than UsesLedgerData; see that trait for why the distinction matters.
 *
 * Assertions about a fallback compare against the page's OWN default rather
 * than a literal year. resolveFiscalYear() falls back to the current FY only
 * when the user has data for it, otherwise to their latest year — so for a user
 * whose budget stops at FY2025, 2025 IS the correct answer to a malformed
 * request, and a literal assertion would fail on correct behaviour.
 */
class DashboardFiscalYearTest extends TestCase
{
    use RefreshDatabase;
    use UsesBudgetData;

    private function visit(array $query = [])
    {
        return $this->actingAs($this->budgetUser())
            ->withoutMiddleware(EnsureUserIsActive::class)
            ->get('/dashboard'.($query ? '?'.http_build_query($query) : ''));
    }

    private function props(array $query = []): array
    {
        return $this->visit($query)->viewData('page')['props'];
    }

    public function test_page_exposes_the_fiscal_year_navigation_contract(): void
    {
        $this->visit()
            ->assertOk()
            ->assertInertia(fn (AssertableInertia $page) => $page
                ->component('Dashboard')
                ->has('years')
                ->has('fyNav')
                ->has('activeFiscalYear')
                ->has('currentFiscalYear')
                ->etc()
            );
    }

    public function test_fiscal_year_is_exposed_under_both_names(): void
    {
        $props = $this->props();

        // FiscalYearHero and every sibling page bind activeFiscalYear; the
        // dashboard's own copy predates it and binds fiscalYear. They must not
        // drift apart, or the control and the KPI sub-labels disagree.
        $this->assertSame($props['fiscalYear'], $props['activeFiscalYear']);
    }

    public function test_a_requested_fiscal_year_is_honoured(): void
    {
        $props = $this->props();
        $years = $props['years'];

        if (count($years) < 2) {
            $this->markTestSkipped('This user has fewer than two budget years, so there is nothing to navigate to.');
        }

        $other = collect($years)->first(fn ($y) => (int) $y !== (int) $props['activeFiscalYear']);

        $this->assertSame((int) $other, $this->props(['fy' => (string) $other])['activeFiscalYear']);
    }

    public function test_fiscal_year_nav_is_null_at_the_boundaries(): void
    {
        $years = $this->props()['years'];

        if (count($years) < 2) {
            $this->markTestSkipped('Boundary navigation needs at least two budget years.');
        }

        $sorted = collect($years)->map(fn ($y) => (int) $y)->sort()->values();

        $this->assertNull($this->props(['fy' => (string) $sorted->first()])['fyNav']['prev']);
        $this->assertNull($this->props(['fy' => (string) $sorted->last()])['fyNav']['next']);
    }

    /**
     * The dashboard's year list is deliberately vw_BudgetAllocation's, shared
     * with the Budget Allocations page down to the cache key. If someone
     * re-points it at vw_FinanceLedger the page still renders — it just quietly
     * starts offering years with no budget baseline.
     */
    public function test_year_list_matches_the_budget_allocations_page(): void
    {
        $budgetPageYears = $this->actingAs($this->budgetUser())
            ->withoutMiddleware(EnsureUserIsActive::class)
            ->get('/budget-allocations')
            ->viewData('page')['props']['years'];

        $this->assertSame($budgetPageYears, $this->props()['years']);
    }

    public static function malformedFiscalYearCases(): array
    {
        return [
            'trailing junk' => ['2025abc'],
            'decimal' => ['2025.0'],
            'not a year' => ['notayear'],
            'empty' => [''],
            'a year with no data' => ['1999'],
        ];
    }

    /**
     * End-to-end cover for the parsing rule; the mechanism itself is asserted
     * offline in DashboardTransformsTest.
     */
    #[DataProvider('malformedFiscalYearCases')]
    public function test_malformed_fiscal_year_falls_back_to_the_default(string $fy): void
    {
        $this->assertSame(
            $this->props()['activeFiscalYear'],
            $this->props(['fy' => $fy])['activeFiscalYear'],
        );
    }

    /**
     * `?fy[]=2025` makes the query param an array. PHP will not coerce that to
     * a string parameter, so before resolveFiscalYear() and budgetTotal() took
     * mixed this was a TypeError — and on the dashboard it was raised at
     * budgetTotal()'s boundary, outside its own try/catch, i.e. a 500.
     */
    public function test_array_fiscal_year_input_does_not_error(): void
    {
        $response = $this->actingAs($this->budgetUser())
            ->withoutMiddleware(EnsureUserIsActive::class)
            ->get('/dashboard?fy[]=2025');

        $response->assertOk();

        // Malformed input is a bad request, not an outage — the warning flash
        // is what would betray the request having fallen into the catch.
        $response->assertSessionMissing('warning');

        $props = $response->viewData('page')['props'];
        $this->assertSame($this->props()['activeFiscalYear'], $props['activeFiscalYear']);
    }

    /**
     * A completed year is a full-year total, not a year-to-date one, and the
     * cutoff must cover all 12 periods.
     */
    public function test_a_past_fiscal_year_reports_a_complete_window(): void
    {
        $props = $this->props();
        $past = collect($props['years'])
            ->map(fn ($y) => (int) $y)
            ->filter(fn ($y) => $y < (int) $props['currentFiscalYear'])
            ->max();

        if ($past === null) {
            $this->markTestSkipped('This user has no completed fiscal year with budget data.');
        }

        $pastProps = $this->props(['fy' => (string) $past]);

        $this->assertTrue($pastProps['expenditureWindowStarted']);
        $this->assertStringStartsWith('SEP', (string) $pastProps['latestPeriodLabel']);
    }
}
