<?php

namespace Tests\Unit;

use App\Concerns\DerivesRequisitionDetail;
use Illuminate\Support\Collection;
use PHPUnit\Framework\TestCase;

/**
 * Offline regression net for the requisition detail pages' arithmetic.
 *
 * Exists for the same reason DerivesAllocationLinesTest does: the feature tests
 * for these pages SKIP when SQL Server is unreachable, which is correct — the
 * snapshot is a hundred thousand rows of derived financial data and cannot be
 * meaningfully faked — but it leaves CI with no coverage at all unless the
 * shaping lives in a DB-free trait and is tested here.
 *
 * These assert the CONSUMPTION of columns the SQL view computes. ExtendedCost
 * is already net of receipts and floored at zero when it arrives; recomputing
 * that here would only test the duplicate.
 */
class DerivesRequisitionDetailTest extends TestCase
{
    use DerivesRequisitionDetail;

    private const COLUMNS = [
        'FinancialYear', 'RequisitionNumber', 'PONumber', 'LineNbr', 'Status', 'StatusName',
        'ReqDateCreated', 'VendorName', 'ItemDescription', 'Department',
        'AccountNumber', 'AccountDescription',
        'OrderQuantity', 'QtyShipped', 'Quantity', 'UnitCost', 'ExtendedCost',
    ];

    /** @return array<string,mixed> */
    private function detailRow(array $overrides = []): array
    {
        return array_merge([
            'FinancialYear' => '2026',
            'RequisitionNumber' => 'REQ0001',
            'PONumber' => 'PO0001',
            'LineNbr' => 1,
            'Status' => 'PO',
            'StatusName' => 'Purchase Order',
            'ReqDateCreated' => '2025-11-04',
            'VendorName' => 'ACME SUPPLIES',
            'ItemDescription' => 'EXAMINATION GLOVES',
            'Department' => 'ADMIN',
            'AccountNumber' => '4-80400-H01-107-1157-00-000',
            'AccountDescription' => 'MEDICAL SUPPLIES',
            'OrderQuantity' => 100.0,
            'QtyShipped' => 0.0,
            'Quantity' => 100.0,
            'UnitCost' => 12.5,
            'ExtendedCost' => 1250.0,
        ], $overrides);
    }

    /** @param array<int,array<string,mixed>> $rows */
    private function shaped(array $rows): Collection
    {
        return collect($rows)->map(fn ($r) => $this->deriveRequisitionRow($r, self::COLUMNS));
    }

    // =========================================================================
    // Row shaping
    // =========================================================================

    public function test_money_and_quantity_columns_arrive_as_floats(): void
    {
        // SQL Server hands decimals back as strings through PDO; a string in the
        // JSON prop means the Vue tabular-nums column right-aligns text and the
        // totals row sums by concatenation.
        $row = $this->deriveRequisitionRow($this->detailRow([
            'OrderQuantity' => '100.0000',
            'QtyShipped' => '25.0000',
            'Quantity' => '75.0000',
            'UnitCost' => '12.5000',
            'ExtendedCost' => '937.50',
        ]), self::COLUMNS);

        foreach (['OrderQuantity', 'QtyShipped', 'Quantity', 'UnitCost', 'ExtendedCost'] as $column) {
            $this->assertIsFloat($row[$column], "{$column} must be a float");
        }

        $this->assertSame(937.50, $row['ExtendedCost']);
    }

    public function test_only_the_requested_columns_are_exposed(): void
    {
        // The view carries UserName and the segment IDs. Neither belongs in a
        // page prop, and the column list is the only thing keeping them out.
        $row = $this->deriveRequisitionRow(
            $this->detailRow(['UserName' => 'KCHARLES1', 'DepartmentID' => '107']),
            self::COLUMNS
        );

        $this->assertArrayNotHasKey('UserName', $row);
        $this->assertArrayNotHasKey('DepartmentID', $row);
        $this->assertSame(self::COLUMNS, array_slice(array_keys($row), 0, count(self::COLUMNS)));
    }

    public function test_a_missing_column_becomes_null_not_a_php_notice(): void
    {
        $row = $this->deriveRequisitionRow(['RequisitionNumber' => 'REQ0001'], self::COLUMNS);

        $this->assertNull($row['VendorName']);
        $this->assertSame(0.0, $row['ExtendedCost']);
    }

    public function test_partially_received_marks_only_lines_with_both_a_receipt_and_a_balance(): void
    {
        $untouched = $this->deriveRequisitionRow($this->detailRow(), self::COLUMNS);
        $partial = $this->deriveRequisitionRow($this->detailRow([
            'QtyShipped' => 40.0, 'Quantity' => 60.0, 'ExtendedCost' => 750.0,
        ]), self::COLUMNS);
        // Fully received: the balance is zero, so there is no commitment left to
        // flag — the cost has landed in the GL as posted spend instead.
        $complete = $this->deriveRequisitionRow($this->detailRow([
            'QtyShipped' => 100.0, 'Quantity' => 0.0, 'ExtendedCost' => 0.0,
        ]), self::COLUMNS);

        $this->assertFalse($untouched['PartiallyReceived']);
        $this->assertTrue($partial['PartiallyReceived']);
        $this->assertFalse($complete['PartiallyReceived']);
    }

    /**
     * The regression net for the Access-parity change.
     *
     * `Quantity` used to be floored at zero in SQL, so `> 0` was a safe test for
     * "has a balance". Parity removed the floor, so an OVER-received line is now
     * negative — and `> 0` classed it as fully unshipped, muting in the table the
     * one row that most needs a human to look at it. See financeupdatesep.md A7b.
     */
    public function test_an_over_received_line_is_flagged_rather_than_read_as_fully_unshipped(): void
    {
        $over = $this->deriveRequisitionRow($this->detailRow([
            'OrderQuantity' => 1.0,
            'QtyShipped' => 2.0,
            'Quantity' => -1.0,
            'UnitCost' => 48000.0,
            'ExtendedCost' => -48000.0,
        ]), self::COLUMNS);

        $this->assertTrue($over['PartiallyReceived'], 'An over-received line still has a receipt and a non-zero balance.');
        $this->assertTrue($over['OverShipped']);
        $this->assertSame(-48000.0, $over['ExtendedCost'], 'A negative commitment must survive unclamped.');
        $this->assertSame(-1.0, $over['Quantity']);
    }

    public function test_over_shipped_is_false_for_every_ordinary_line(): void
    {
        foreach ([
            'untouched' => [],
            'partial' => ['QtyShipped' => 40.0, 'Quantity' => 60.0],
            'complete' => ['QtyShipped' => 100.0, 'Quantity' => 0.0],
        ] as $label => $overrides) {
            $row = $this->deriveRequisitionRow($this->detailRow($overrides), self::COLUMNS);
            $this->assertFalse($row['OverShipped'], "{$label} should not be flagged over-shipped.");
        }
    }

    /**
     * Totals must carry the negative through rather than clamping it, or the
     * page stops tying to the ledger's Approved - which is exactly the
     * disagreement Phase 2's reconciliation gate exists to prevent.
     */
    public function test_totals_carry_a_negative_commitment_through(): void
    {
        $totals = $this->requisitionTotals(new Collection([
            $this->deriveRequisitionRow($this->detailRow(['ExtendedCost' => 193650.0]), self::COLUMNS),
            $this->deriveRequisitionRow($this->detailRow([
                'RequisitionNumber' => 'REQ0002', 'ExtendedCost' => -64550.0, 'Quantity' => -1.0, 'QtyShipped' => 2.0,
            ]), self::COLUMNS),
        ]));

        $this->assertSame(129100.0, $totals['committed']);
        $this->assertSame(2, $totals['lines']);
    }

    /**
     * `largest` means the biggest commitment, not the biggest absolute number. A
     * large negative is a data condition, not the headline figure for the card.
     */
    public function test_the_largest_line_is_the_maximum_not_the_maximum_absolute(): void
    {
        $totals = $this->requisitionTotals(new Collection([
            $this->deriveRequisitionRow($this->detailRow([
                'ItemDescription' => 'A modest commitment', 'ExtendedCost' => 500.0,
            ]), self::COLUMNS),
            $this->deriveRequisitionRow($this->detailRow([
                'RequisitionNumber' => 'REQ0002', 'ItemDescription' => 'An over-receipt', 'ExtendedCost' => -900000.0,
            ]), self::COLUMNS),
        ]));

        $this->assertSame(500.0, $totals['largest']['amount']);
        $this->assertSame('A modest commitment', $totals['largest']['label']);
    }

    // =========================================================================
    // Totals
    // =========================================================================

    public function test_totals_sum_the_whole_set(): void
    {
        $totals = $this->requisitionTotals($this->shaped([
            $this->detailRow(['ExtendedCost' => 1250.0, 'Quantity' => 100.0]),
            $this->detailRow(['RequisitionNumber' => 'REQ0002', 'ExtendedCost' => 99.99, 'Quantity' => 3.0]),
        ]));

        $this->assertSame(1349.99, $totals['committed']);
        $this->assertSame(103.0, $totals['quantity']);
        $this->assertSame(2, $totals['lines']);
    }

    public function test_requisitions_are_counted_distinctly_not_by_line(): void
    {
        // A nine-line requisition is one requisition. A card that said otherwise
        // would disagree with anything finance counts by hand.
        $totals = $this->requisitionTotals($this->shaped([
            $this->detailRow(['LineNbr' => 1]),
            $this->detailRow(['LineNbr' => 2]),
            $this->detailRow(['RequisitionNumber' => 'REQ0002', 'LineNbr' => 1]),
        ]));

        $this->assertSame(3, $totals['lines']);
        $this->assertSame(2, $totals['requisitions']);
    }

    public function test_vendor_and_account_counts_ignore_blanks(): void
    {
        $totals = $this->requisitionTotals($this->shaped([
            $this->detailRow(),
            $this->detailRow(['RequisitionNumber' => 'REQ0002', 'VendorName' => null, 'AccountNumber' => null]),
            $this->detailRow(['RequisitionNumber' => 'REQ0003', 'VendorName' => 'BETA LTD']),
        ]));

        $this->assertSame(2, $totals['vendors']);
        $this->assertSame(1, $totals['accounts']);
    }

    public function test_the_largest_line_is_by_committed_cost_not_quantity(): void
    {
        $totals = $this->requisitionTotals($this->shaped([
            $this->detailRow(['ItemDescription' => 'BULK PAPER', 'Quantity' => 5000.0, 'ExtendedCost' => 500.0]),
            $this->detailRow(['ItemDescription' => 'ULTRASOUND', 'Quantity' => 1.0, 'ExtendedCost' => 480000.0]),
        ]));

        $this->assertSame(480000.0, $totals['largest']['amount']);
        $this->assertSame('ULTRASOUND', $totals['largest']['label']);
    }

    public function test_the_largest_line_falls_back_to_the_account_when_the_item_is_blank(): void
    {
        $totals = $this->requisitionTotals($this->shaped([
            $this->detailRow(['ItemDescription' => '', 'ExtendedCost' => 42.0]),
        ]));

        $this->assertSame('MEDICAL SUPPLIES', $totals['largest']['label']);
    }

    public function test_totals_of_an_empty_set_are_zero_and_labelless(): void
    {
        $totals = $this->requisitionTotals(collect());

        $this->assertSame(0.0, $totals['committed']);
        $this->assertSame(0, $totals['requisitions']);
        $this->assertNull($totals['largest']['label']);
    }

    // =========================================================================
    // The outage path cannot drift from the success path
    // =========================================================================

    public function test_the_empty_totals_have_exactly_the_same_keys_as_a_real_set(): void
    {
        // A key present on one path and missing on the other is a Vue error
        // stacked on top of an outage. This is the cheap guard for that.
        $real = $this->requisitionTotals($this->shaped([$this->detailRow()]));
        $empty = $this->emptyRequisitionTotals();

        $this->assertSame(array_keys($real), array_keys($empty));
        $this->assertSame(array_keys($real['largest']), array_keys($empty['largest']));
    }

    public function test_the_empty_totals_are_all_zero(): void
    {
        $empty = $this->emptyRequisitionTotals();

        $this->assertSame(0.0, $empty['committed']);
        $this->assertSame(0.0, $empty['quantity']);
        $this->assertSame(0, $empty['lines']);
        $this->assertSame(0, $empty['requisitions']);
        $this->assertSame(0, $empty['vendors']);
        $this->assertSame(0, $empty['accounts']);
        $this->assertSame(['amount' => 0.0, 'label' => null], $empty['largest']);
    }
}
