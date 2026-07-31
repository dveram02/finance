<?php

namespace Tests\Feature;

use App\Http\Controllers\AllocationLineExpenditureController;
use App\Http\Middleware\EnsureUserIsActive;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Inertia\Testing\AssertableInertia;
use Tests\TestCase;

/**
 * Allocation Line Expenditure is a scaffold — figures are hardcoded and it
 * touches no SQL Server connection, so it is fully testable in CI.
 * EnsureUserIsActive is excluded because that middleware does reach SQL Server.
 *
 * The balance and status rules are the reason this page exists, so they are
 * asserted directly rather than only through the rendered contract.
 */
class AllocationLineExpenditureTest extends TestCase
{
    use RefreshDatabase;

    private function visit(array $query = [])
    {
        return $this->actingAs(User::factory()->create())
            ->withoutMiddleware(EnsureUserIsActive::class)
            ->get('/allocation-line-expenditure'.($query ? '?'.http_build_query($query) : ''));
    }

    /** @return array<int,array<string,mixed>> every row across every page */
    private function allRows(): array
    {
        $rows = [];
        $page = 1;

        do {
            $props = $this->visit(['page' => $page])->viewData('page')['props'];
            $rows = array_merge($rows, $props['rows']['data']);
            $lastPage = $props['rows']['last_page'];
            $page++;
        } while ($page <= $lastPage);

        return $rows;
    }

    public function test_page_is_displayed_with_the_expected_prop_contract(): void
    {
        $this->visit()
            ->assertOk()
            ->assertInertia(fn (AssertableInertia $page) => $page
                ->component('Expenditure/Allocation Line Expenditure')
                ->has('rows.data')
                ->has('clusters')
                ->has('institutions')
                ->has('departments')
                ->has('descriptions')
                ->has('accounts')
                ->has('months', 12)
                ->has('years')
                ->has('stats.totalAllocation')
                ->has('stats.totalExpenditure')
                ->has('stats.balance')
                ->has('stats.exceededCount')
                ->has('totals.months', 12)
                ->has('totals.allocation')
                ->has('totals.encumbered')
                ->has('totals.ytd')
                ->has('totals.balance')
                ->where('isScaffold', true)
            );
    }

    public function test_it_requires_authentication(): void
    {
        $this->get('/allocation-line-expenditure')->assertRedirect('/login');
    }

    public function test_ytd_expenditure_is_the_sum_of_the_twelve_months(): void
    {
        foreach ($this->allRows() as $row) {
            $sum = 0.0;
            foreach (AllocationLineExpenditureController::MONTHS as $month) {
                $this->assertArrayHasKey($month, $row, "Row is missing month {$month}.");
                $sum += (float) $row[$month];
            }

            $this->assertEqualsWithDelta(
                (float) $row['YTDTotal'], $sum, 0.01,
                "YTDTotal does not equal the sum of the months for {$row['AccountNumber']}."
            );
        }
    }

    public function test_balance_is_allocation_less_expenditure_and_never_negative(): void
    {
        foreach ($this->allRows() as $row) {
            $allocation = (float) $row['Allocation'];
            $ytd = (float) $row['YTDTotal'];
            $balance = (float) $row['AllocationBalance'];

            $this->assertGreaterThanOrEqual(
                0.0, $balance,
                "Balance went negative for {$row['AccountNumber']}; overspend belongs in the status, not the balance."
            );

            $expected = $ytd >= $allocation ? 0.0 : round($allocation - $ytd, 2);

            $this->assertEqualsWithDelta(
                $expected, $balance, 0.01,
                "Balance is wrong for {$row['AccountNumber']}."
            );
        }
    }

    public function test_status_classifies_each_line_against_its_allocation(): void
    {
        foreach ($this->allRows() as $row) {
            $allocation = (float) $row['Allocation'];
            $ytd = (float) $row['YTDTotal'];
            $delta = round($ytd - $allocation, 2);

            if (abs($delta) < 0.005) {
                $this->assertSame('exact', $row['StatusKey'], "Equal spend should read as exact for {$row['AccountNumber']}.");
                $this->assertEqualsWithDelta(0.0, (float) $row['StatusAmount'], 0.01);

                continue;
            }

            if ($delta > 0) {
                $this->assertSame('over', $row['StatusKey'], "Overspend should read as over for {$row['AccountNumber']}.");
                // The status amount is the overspend itself, not the balance.
                $this->assertEqualsWithDelta($delta, (float) $row['StatusAmount'], 0.01);
                $this->assertEqualsWithDelta(0.0, (float) $row['AllocationBalance'], 0.01);

                continue;
            }

            $this->assertSame('under', $row['StatusKey'], "Underspend should read as under for {$row['AccountNumber']}.");
            $this->assertEqualsWithDelta(abs($delta), (float) $row['StatusAmount'], 0.01);
            // Under budget: the remaining amount and the balance are the same figure.
            $this->assertEqualsWithDelta(
                (float) $row['AllocationBalance'], (float) $row['StatusAmount'], 0.01
            );
        }
    }

    public function test_sample_data_exercises_all_three_status_outcomes(): void
    {
        // Guards the tests above: if the fixtures only ever produced one branch,
        // they would pass while leaving the other two paths unverified.
        $keys = array_unique(array_column($this->allRows(), 'StatusKey'));
        sort($keys);

        $this->assertSame(['exact', 'over', 'under'], $keys);
    }

    public function test_totals_cover_the_whole_filtered_set_and_reconcile(): void
    {
        $props = $this->visit()->viewData('page')['props'];
        $all = $this->allRows();

        $this->assertGreaterThan(
            count($props['rows']['data']), $props['rows']['total'],
            'Expected the sample data to span more than one page.'
        );

        foreach (['Allocation' => 'allocation', 'Encumbered' => 'encumbered', 'YTDTotal' => 'ytd', 'AllocationBalance' => 'balance'] as $rowKey => $totalKey) {
            $this->assertEqualsWithDelta(
                array_sum(array_column($all, $rowKey)),
                (float) $props['totals'][$totalKey],
                0.05,
                "Total for {$totalKey} does not match the sum of every row."
            );
        }

        $this->assertSame(
            count(array_filter($all, fn ($r) => $r['StatusKey'] === 'over')),
            $props['totals']['exceededCount']
        );
    }

    public function test_a_valid_filter_narrows_the_result_set(): void
    {
        $all = $this->visit()->viewData('page')['props']['rows']['total'];
        $department = $this->visit()->viewData('page')['props']['departments'][0];

        $filtered = $this->visit(['department' => $department])->viewData('page')['props'];

        $this->assertSame($department, $filtered['filters']['department']);
        $this->assertLessThan($all, $filtered['rows']['total']);
        $this->assertNotEmpty($filtered['rows']['data']);
    }

    public function test_an_unknown_filter_value_is_discarded_rather_than_applied(): void
    {
        $props = $this->visit(['description' => 'NOT A REAL DESCRIPTION'])
            ->assertOk()
            ->viewData('page')['props'];

        $this->assertNull($props['filters']['description']);
        $this->assertNotEmpty($props['rows']['data']);
    }
}
