<?php

namespace Tests\Feature;

use App\Http\Controllers\AllocationLineExpenditureController;
use App\Http\Middleware\EnsureUserIsActive;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Inertia\Testing\AssertableInertia;
use Tests\Feature\Concerns\UsesLedgerData;
use Tests\TestCase;

/**
 * Allocation Line Expenditure reads dbo.vw_FinanceLedger, so these tests need a
 * reachable SQL Server holding a populated snapshot; they skip when they cannot
 * get one (see UsesLedgerData). EnsureUserIsActive is excluded because that
 * middleware reaches the separate auth SQL Server.
 *
 * The balance and status rules are the reason this page exists, so they are
 * asserted directly rather than only through the rendered contract. Note the
 * rule is stated against ActualExpenditure (YTD + Approved + Routing), NOT YTD
 * alone: money committed on an approved or routing requisition is no longer
 * available to spend, so measuring against posted GL activity alone would
 * overstate the headroom on every line with an open commitment.
 */
class AllocationLineExpenditureTest extends TestCase
{
    use RefreshDatabase;
    use UsesLedgerData;

    private function visit(array $query = [])
    {
        return $this->actingAs($this->ledgerUser())
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
            );
    }

    public function test_it_requires_authentication(): void
    {
        $this->get('/allocation-line-expenditure')->assertRedirect('/login');
    }

    public function test_the_page_is_not_empty_for_a_user_with_ledger_rows(): void
    {
        // Guards every row-level assertion below: an empty page would turn each
        // foreach into a silent no-op rather than a failure.
        $props = $this->visit()->viewData('page')['props'];

        $this->assertNotEmpty($props['rows']['data'], 'The ledger returned no rows for a user that should have them.');
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

    public function test_encumbered_is_approved_plus_routing(): void
    {
        foreach ($this->allRows() as $row) {
            $this->assertEqualsWithDelta(
                (float) $row['Approved'] + (float) $row['Routing'],
                (float) $row['Encumbered'],
                0.01,
                "Encumbered does not equal Approved + Routing for {$row['AccountNumber']}."
            );
        }
    }

    public function test_actual_expenditure_is_ytd_plus_the_encumbered_commitment(): void
    {
        foreach ($this->allRows() as $row) {
            $this->assertEqualsWithDelta(
                (float) $row['YTDTotal'] + (float) $row['Approved'] + (float) $row['Routing'],
                (float) $row['ActualExpenditure'],
                0.01,
                "ActualExpenditure does not reconcile for {$row['AccountNumber']}."
            );
        }
    }

    public function test_balance_is_allocation_less_actual_expenditure_and_never_negative(): void
    {
        foreach ($this->allRows() as $row) {
            $allocation = (float) $row['Allocation'];
            $actual = (float) $row['ActualExpenditure'];
            $balance = (float) $row['AllocationBalance'];

            $this->assertGreaterThanOrEqual(
                0.0, $balance,
                "Balance went negative for {$row['AccountNumber']}; overspend belongs in the status, not the balance."
            );

            $expected = $actual >= $allocation ? 0.0 : round($allocation - $actual, 2);

            $this->assertEqualsWithDelta(
                $expected, $balance, 0.01,
                "Balance is wrong for {$row['AccountNumber']}."
            );
        }
    }

    public function test_status_classifies_each_line_against_its_allocation(): void
    {
        foreach ($this->allRows() as $row) {
            $delta = round((float) $row['ActualExpenditure'] - (float) $row['Allocation'], 2);

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

    public function test_totals_cover_the_whole_filtered_set_and_reconcile(): void
    {
        $props = $this->visit()->viewData('page')['props'];
        $all = $this->allRows();

        foreach (['Allocation' => 'allocation', 'Encumbered' => 'encumbered', 'YTDTotal' => 'ytd', 'AllocationBalance' => 'balance'] as $rowKey => $totalKey) {
            $this->assertEqualsWithDelta(
                array_sum(array_map('floatval', array_column($all, $rowKey))),
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
        $props = $this->visit()->viewData('page')['props'];

        if (count($props['departments']) < 2) {
            $this->markTestSkipped('The ledger holds one department for this user, so no filter can narrow the set.');
        }

        $department = $props['departments'][0];
        $filtered = $this->visit(['department' => $department])->viewData('page')['props'];

        $this->assertSame($department, $filtered['filters']['department']);
        $this->assertLessThan($props['rows']['total'], $filtered['rows']['total']);
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
