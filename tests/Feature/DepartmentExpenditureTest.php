<?php

namespace Tests\Feature;

use App\Http\Controllers\DepartmentExpenditureController;
use App\Http\Middleware\EnsureUserIsActive;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Inertia\Testing\AssertableInertia;
use Tests\Feature\Concerns\UsesLedgerData;
use Tests\TestCase;

/**
 * The Department Expenditure page reads dbo.vw_FinanceLedger, so these tests
 * need a reachable SQL Server holding a populated snapshot; they skip when they
 * cannot get one (see UsesLedgerData). EnsureUserIsActive is excluded because
 * that middleware reaches the separate auth SQL Server.
 *
 * The assertions are about invariants the controller must hold for ANY data —
 * that YTD reconciles with its own months, that totals span the whole filtered
 * set rather than the visible page, that an unknown filter is discarded. Where
 * an assertion needs the data to have a particular shape (more than one page,
 * more than one cluster), the premise is guarded and skipped rather than
 * assumed, because the ledger content is not ours to control.
 */
class DepartmentExpenditureTest extends TestCase
{
    use RefreshDatabase;
    use UsesLedgerData;

    private function visit(array $query = [])
    {
        return $this->actingAs($this->ledgerUser())
            ->withoutMiddleware(EnsureUserIsActive::class)
            ->get('/department-expenditure'.($query ? '?'.http_build_query($query) : ''));
    }

    /** @return array<int,array<string,mixed>> every row across every page */
    private function allRows(array $query = []): array
    {
        $rows = [];
        $page = 1;

        do {
            $props = $this->visit($query + ['page' => $page])->viewData('page')['props'];
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
                ->has('activeFiscalYear')
                ->has('currentFiscalYear')
            );
    }

    public function test_it_requires_authentication(): void
    {
        $this->get('/department-expenditure')->assertRedirect('/login');
    }

    public function test_the_page_is_not_empty_for_a_user_with_ledger_rows(): void
    {
        // Guards every other test here: acting as a user the ledger does not
        // recognise returns an empty page, which would turn each assertion
        // below into a silent no-op rather than a failure.
        $props = $this->visit()->viewData('page')['props'];

        $this->assertNotEmpty($props['rows']['data'], 'The ledger returned no rows for a user that should have them.');
    }

    public function test_every_row_carries_all_twelve_fiscal_months_and_a_reconciling_ytd(): void
    {
        foreach ($this->allRows() as $row) {
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
    }

    public function test_column_totals_cover_the_whole_filtered_set_not_just_the_visible_page(): void
    {
        $props = $this->visit()->viewData('page')['props'];
        $all = $this->allRows();

        foreach (DepartmentExpenditureController::MONTHS as $month) {
            $this->assertEqualsWithDelta(
                array_sum(array_map('floatval', array_column($all, $month))),
                (float) $props['totals']['months'][$month],
                0.05,
                "Total for {$month} does not match the sum of every row."
            );
        }

        // And the grand total must reconcile with the twelve column totals.
        $this->assertEqualsWithDelta(
            (float) $props['totals']['ytd'],
            array_sum(array_map('floatval', $props['totals']['months'])),
            0.05,
            'Grand total does not reconcile with the monthly column totals.'
        );

        if ($props['rows']['total'] <= count($props['rows']['data'])) {
            $this->markTestSkipped('The ledger returned a single page, so this cannot distinguish page totals from set totals.');
        }

        // With more than one page, the set total must exceed page one alone.
        $pageOnlyYtd = array_sum(array_map('floatval', array_column($props['rows']['data'], 'YTDTotal')));

        if ($pageOnlyYtd > 0) {
            $this->assertGreaterThan(
                $pageOnlyYtd, (float) $props['totals']['ytd'],
                'The grand total looks like it only sums the current page.'
            );
        }
    }

    public function test_months_after_the_current_fiscal_period_are_flagged_future(): void
    {
        $props = $this->visit()->viewData('page')['props'];

        // Ask for a year the ledger actually holds. Requesting an absent FY is
        // not a way to test this: resolveFiscalYear() deliberately falls back to
        // the current year, so the page would answer about a different FY than
        // the one asserted and the test would read as a bug in `future`.
        $past = collect($props['years'])
            ->map(fn ($y) => (int) $y)
            ->filter(fn (int $y) => $y < $props['currentFiscalYear'])
            ->min();

        if ($past === null) {
            $this->markTestSkipped('The ledger holds no completed fiscal year for this user.');
        }

        // A completed FY — every month has elapsed, so none may be flagged future.
        $this->visit(['fy' => $past])->assertInertia(fn (AssertableInertia $page) => $page
            ->where('activeFiscalYear', $past)
            ->where('months', fn ($months) => collect($months)->every(fn ($m) => $m['future'] === false))
        );
    }

    public function test_an_unknown_filter_value_is_discarded_rather_than_applied(): void
    {
        // A stale filter carried across an FY switch must not silently empty the
        // table — the controller drops values that are not valid options.
        $props = $this->visit(['cluster' => 'NOT A REAL CLUSTER'])
            ->assertOk()
            ->viewData('page')['props'];

        $this->assertNull($props['filters']['cluster']);
        $this->assertNotEmpty($props['rows']['data']);
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
}
