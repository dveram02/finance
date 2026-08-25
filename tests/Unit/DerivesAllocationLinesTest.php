<?php

namespace Tests\Unit;

use App\Concerns\DerivesAllocationLines;
use App\Models\FinanceLedger;
use Illuminate\Support\Collection;
use PHPUnit\Framework\TestCase;

/**
 * Offline regression net for the allocation rule.
 *
 * This suite exists because the ledger feature tests SKIP when SQL Server is
 * unreachable — correctly so, since megabytes of derived financial data cannot
 * be meaningfully faked. But that leaves CI with no coverage of the rule at
 * all, and this change altered it. The arithmetic lives in a DB-free trait
 * precisely so it can be tested here, the same reasoning as
 * DashboardDataTransforms.
 *
 * THE RULE UNDER TEST (2026-08-25):
 *     ActualExpenditure = YTDTotal + Approved
 *     Excess            = MAX(0, YTDTotal - Allocation)
 *     AllocationBalance = MAX(0, Allocation - YTDTotal)
 *     Routing           = carried, deducted from nothing
 *
 * Note these assert the CONSUMPTION of columns the SQL view computes, not a
 * PHP reimplementation of them. Recomputing the formula here would only test
 * the duplicate. The SQL itself is verified by the feature suite against a real
 * database.
 */
class DerivesAllocationLinesTest extends TestCase
{
    use DerivesAllocationLines;

    private const MONTHS = FinanceLedger::MONTHS;

    /** @return array<string,mixed> */
    private function ledgerRow(array $overrides = []): array
    {
        return array_merge(
            array_fill_keys(self::MONTHS, 0),
            [
                'FinancialYear' => '2026',
                'ClusterName' => 'CENTRAL',
                'InstitutionName' => 'HOSPITAL',
                'Responsibility' => 'FINANCE',
                'DepartmentName' => 'ADMIN',
                'AccountNumber' => '4-80400-H01-107-1157-00-000',
                'AccountDescription' => 'OFFICE SUPPLIES',
                'Allocation' => 1000.0,
                'Approved' => 0.0,
                'Routing' => 0.0,
                'YTDTotal' => 0.0,
                'ActualExpenditure' => 0.0,
                'Excess' => 0.0,
                'AllocationBalance' => 1000.0,
            ],
            $overrides,
        );
    }

    /** @return array<int,string> */
    private function columns(): array
    {
        return array_merge([
            'FinancialYear', 'ClusterName', 'InstitutionName', 'Responsibility', 'DepartmentName',
            'AccountNumber', 'AccountDescription', 'Allocation', 'Approved', 'Routing',
            'YTDTotal', 'ActualExpenditure', 'Excess', 'AllocationBalance',
        ], self::MONTHS);
    }

    // =========================================================================
    // The rule
    // =========================================================================

    public function test_routing_is_carried_but_never_folded_into_another_figure(): void
    {
        $row = $this->deriveAllocationLine(
            $this->ledgerRow([
                'YTDTotal' => 300.0,
                'Approved' => 200.0,
                'Routing' => 400.0,
                'ActualExpenditure' => 500.0,   // 300 + 200, Routing excluded
                'AllocationBalance' => 700.0,   // 1000 - 300, Routing excluded
            ]),
            $this->columns(),
            self::MONTHS,
        );

        $this->assertSame(400.0, $row['Routing'], 'Routing must survive as its own column.');
        $this->assertSame(500.0, $row['ActualExpenditure']);
        $this->assertSame(700.0, $row['AllocationBalance']);
    }

    public function test_the_encumbered_column_is_gone(): void
    {
        // Approved and Routing are no longer interchangeable: one counts toward
        // the reported actual, the other counts toward nothing. Summing them
        // into a single "Encumbered" figure and showing it beside a balance
        // that ignores both is what this change deliberately removed.
        $row = $this->deriveAllocationLine(
            $this->ledgerRow(['Approved' => 200.0, 'Routing' => 400.0]),
            $this->columns(),
            self::MONTHS,
        );

        $this->assertArrayNotHasKey('Encumbered', $row);
    }

    public function test_numeric_columns_are_cast_to_float(): void
    {
        // SQL Server returns money as strings through the driver; the Vue table
        // does arithmetic-free formatting but the totals row sums these.
        $row = $this->deriveAllocationLine(
            $this->ledgerRow(['YTDTotal' => '1234.56', 'Approved' => '78.90']),
            $this->columns(),
            self::MONTHS,
        );

        $this->assertSame(1234.56, $row['YTDTotal']);
        $this->assertSame(78.90, $row['Approved']);
        $this->assertIsString($row['AccountNumber'], 'Non-numeric columns must be left alone.');
    }

    // =========================================================================
    // Classification
    // =========================================================================

    public function test_classification_reads_the_ledgers_own_excess_and_balance(): void
    {
        $this->assertSame(['over', 250.0], $this->classifyAllocationLine(250.0, 0.0));
        $this->assertSame(['under', 400.0], $this->classifyAllocationLine(0.0, 400.0));
        $this->assertSame(['exact', 0.0], $this->classifyAllocationLine(0.0, 0.0));
    }

    public function test_sub_half_cent_amounts_classify_as_exact(): void
    {
        // Both sides are rounded money, but comparing floats for exact equality
        // is unsafe: half a cent of tolerance decides "fully spent".
        $this->assertSame(['exact', 0.0], $this->classifyAllocationLine(0.004, 0.0));
        $this->assertSame(['exact', 0.0], $this->classifyAllocationLine(0.0, 0.004));
        $this->assertSame('over', $this->classifyAllocationLine(0.005, 0.0)[0]);
        $this->assertSame('under', $this->classifyAllocationLine(0.0, 0.005)[0]);
    }

    public function test_excess_wins_when_both_are_somehow_non_zero(): void
    {
        // The view floors the balance at zero and reports overspend separately,
        // so exactly one can be non-zero. If that invariant is ever broken, an
        // overspend must not be reported as available headroom.
        $this->assertSame('over', $this->classifyAllocationLine(100.0, 100.0)[0]);
    }

    // =========================================================================
    // Totals
    // =========================================================================

    public function test_totals_sum_the_whole_set_and_keep_approved_and_routing_apart(): void
    {
        $rows = new Collection([
            $this->deriveAllocationLine($this->ledgerRow([
                'Allocation' => 1000.0, 'YTDTotal' => 300.0, 'Approved' => 200.0,
                'Routing' => 50.0, 'ActualExpenditure' => 500.0, 'AllocationBalance' => 700.0,
                'Oct' => 300.0,
            ]), $this->columns(), self::MONTHS),
            $this->deriveAllocationLine($this->ledgerRow([
                'Allocation' => 500.0, 'YTDTotal' => 800.0, 'Approved' => 100.0,
                'Routing' => 25.0, 'ActualExpenditure' => 900.0, 'Excess' => 300.0,
                'AllocationBalance' => 0.0, 'Nov' => 800.0,
            ]), $this->columns(), self::MONTHS),
        ]);

        $totals = $this->allocationTotals($rows, self::MONTHS);

        $this->assertSame(1500.0, $totals['allocation']);
        $this->assertSame(1100.0, $totals['ytd']);
        $this->assertSame(300.0, $totals['approved']);
        $this->assertSame(75.0, $totals['routing']);
        $this->assertSame(1400.0, $totals['actual']);
        $this->assertSame(300.0, $totals['months']['Oct']);
        $this->assertSame(800.0, $totals['months']['Nov']);
        $this->assertSame(1, $totals['exceededCount']);
    }

    public function test_balance_is_summed_per_line_so_overspend_cannot_create_headroom(): void
    {
        // The overspent line contributes ZERO balance, not a negative one.
        // Netting -300 against the other line's 700 would report 400 available
        // when 700 genuinely is — overstating one budget by understating it
        // against a completely unrelated account.
        $rows = new Collection([
            $this->deriveAllocationLine($this->ledgerRow([
                'Allocation' => 1000.0, 'YTDTotal' => 300.0, 'AllocationBalance' => 700.0,
            ]), $this->columns(), self::MONTHS),
            $this->deriveAllocationLine($this->ledgerRow([
                'Allocation' => 500.0, 'YTDTotal' => 800.0,
                'Excess' => 300.0, 'AllocationBalance' => 0.0,
            ]), $this->columns(), self::MONTHS),
        ]);

        $this->assertSame(700.0, $this->allocationTotals($rows, self::MONTHS)['balance']);
    }

    public function test_empty_totals_have_exactly_the_same_shape_as_real_totals(): void
    {
        // The outage path renders the same Inertia component. A key present on
        // one path and missing on the other is a Vue error stacked on top of an
        // outage — the worst moment to discover it.
        $real = $this->allocationTotals(
            new Collection([$this->deriveAllocationLine($this->ledgerRow(), $this->columns(), self::MONTHS)]),
            self::MONTHS,
        );
        $empty = $this->emptyAllocationTotals(self::MONTHS);

        $this->assertSame(array_keys($real), array_keys($empty));
        $this->assertSame(array_keys($real['months']), array_keys($empty['months']));
    }

    public function test_totals_of_an_empty_set_are_zero_not_null(): void
    {
        $totals = $this->allocationTotals(new Collection, self::MONTHS);

        $this->assertSame(0.0, $totals['allocation']);
        $this->assertSame(0.0, $totals['actual']);
        $this->assertSame(0, $totals['exceededCount']);
    }
}
