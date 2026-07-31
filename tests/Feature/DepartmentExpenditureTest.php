<?php

namespace Tests\Feature;

use App\Http\Controllers\DepartmentExpenditureController;
use App\Http\Middleware\EnsureUserIsActive;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Inertia\Testing\AssertableInertia;
use Tests\TestCase;

/**
 * The Department Expenditure page is a scaffold — its figures are hardcoded and it
 * touches no SQL Server connection, so unlike the other finance pages it is
 * fully testable in CI. EnsureUserIsActive is excluded because that middleware
 * does reach SQL Server.
 */
class DepartmentExpenditureTest extends TestCase
{
    use RefreshDatabase;

    private function visit(array $query = [])
    {
        return $this->actingAs(User::factory()->create())
            ->withoutMiddleware(EnsureUserIsActive::class)
            ->get('/department-expenditure'.($query ? '?'.http_build_query($query) : ''));
    }

    public function test_page_is_displayed_with_the_expected_prop_contract(): void
    {
        $this->visit()
            ->assertOk()
            ->assertInertia(fn (AssertableInertia $page) => $page
                ->component('Expenditure/Department Expenditure')
                ->has('rows.data')
                ->has('clusters')
                ->has('institutions')
                ->has('responsibilities')
                ->has('departments')
                ->has('months', 12)
                ->has('years')
                ->has('stats.totalExpenditure')
                ->has('stats.highestMonth')
                ->has('stats.accountCount')
                ->has('totals.months', 12)
                ->has('totals.ytd')
                ->has('fyNav')
                ->where('isScaffold', true)
            );
    }

    public function test_it_requires_authentication(): void
    {
        $this->get('/department-expenditure')->assertRedirect('/login');
    }

    public function test_every_row_carries_all_twelve_fiscal_months_and_a_reconciling_ytd(): void
    {
        $this->visit()->assertInertia(function (AssertableInertia $page) {
            foreach ($page->toArray()['props']['rows']['data'] as $row) {
                $sum = 0.0;
                foreach (DepartmentExpenditureController::MONTHS as $month) {
                    $this->assertArrayHasKey($month, $row, "Row is missing month {$month}.");
                    $sum += (float) $row[$month];
                }

                // A YTD that disagrees with its own months is the failure most
                // likely to go unnoticed on a 16-column table.
                $this->assertEqualsWithDelta(
                    (float) $row['YTDTotal'], $sum, 0.01,
                    "YTDTotal does not reconcile for {$row['AccountNumber']}."
                );
            }
        });
    }

    public function test_column_totals_cover_the_whole_filtered_set_not_just_the_visible_page(): void
    {
        $props = $this->visit()->viewData('page')['props'];

        // Guard the premise: with one page this assertion would prove nothing.
        $this->assertGreaterThan(
            count($props['rows']['data']), $props['rows']['total'],
            'Expected the sample data to span more than one page.'
        );

        $pageOnly = [];
        foreach (DepartmentExpenditureController::MONTHS as $month) {
            $pageOnly[$month] = array_sum(array_column($props['rows']['data'], $month));
        }

        // Every month's total must exceed what page one alone accounts for.
        foreach (DepartmentExpenditureController::MONTHS as $month) {
            if ($pageOnly[$month] <= 0) {
                continue;
            }

            $this->assertGreaterThan(
                $pageOnly[$month], (float) $props['totals']['months'][$month],
                "Total for {$month} looks like it only sums the current page."
            );
        }

        // And the grand total must reconcile with the twelve column totals.
        $this->assertEqualsWithDelta(
            (float) $props['totals']['ytd'],
            array_sum(array_map('floatval', $props['totals']['months'])),
            0.05,
            'Grand total does not reconcile with the monthly column totals.'
        );
    }

    public function test_months_after_the_current_fiscal_period_are_flagged_future(): void
    {
        // FY far in the past — every month has elapsed, so none may be future.
        $this->visit(['fy' => 2023])->assertInertia(fn (AssertableInertia $page) => $page
            ->where('months', fn ($months) => collect($months)->every(fn ($m) => $m['future'] === false))
        );
    }

    public function test_an_unknown_filter_value_is_discarded_rather_than_applied(): void
    {
        // A stale filter carried across an FY switch must not silently empty the
        // table — the controller drops values that are not valid options.
        $response = $this->visit(['cluster' => 'NOT A REAL CLUSTER'])->assertOk();

        $props = $response->viewData('page')['props'];

        $this->assertNull($props['filters']['cluster']);
        $this->assertNotEmpty($props['rows']['data']);
    }

    public function test_a_valid_filter_narrows_the_result_set(): void
    {
        $all = $this->visit()->viewData('page')['props']['rows']['total'];

        $cluster = $this->visit()->viewData('page')['props']['clusters'][0];

        $filtered = $this->visit(['cluster' => $cluster])->viewData('page')['props'];

        $this->assertSame($cluster, $filtered['filters']['cluster']);
        $this->assertLessThan($all, $filtered['rows']['total']);
        $this->assertNotEmpty($filtered['rows']['data']);
    }
}
