<?php

namespace App\Concerns;

use Illuminate\Support\Collection;

/**
 * Pure shaping helpers for the two requisition detail pages — no database, no
 * dates, no request. Extracted for the same reason DerivesAllocationLines is:
 * the ledger feature tests SKIP when SQL Server is unreachable, so without a
 * DB-free seam the arithmetic on these pages would have no regression net in
 * CI at all.
 *
 * WHAT THE MONEY COLUMNS MEAN — the three that are routinely misread:
 *
 *   OrderQuantity  what was ordered on the line.
 *   QtyShipped     what has been received against it.
 *   Quantity       the UNSHIPPED BALANCE (the view aliases ActBalance to this),
 *                  floored at zero so an over-shipped line is not a negative
 *                  commitment.
 *   ExtendedCost   Quantity x UnitCost — the commitment NET OF RECEIPTS, not
 *                  the source table's raw ExtendedCost, which double-counts a
 *                  received line (once as a commitment, again as GL actual).
 *
 * So ExtendedCost summed over AP/PO lines IS the summary's Approved for that
 * account, and over RT/HD/PN lines IS its Routing. That equality is enforced in
 * SQL by Phase 2's reconciliation gate; nothing here may quietly redefine it.
 */
trait DerivesRequisitionDetail
{
    /**
     * Columns read as money/quantity and cast to float on the way in.
     *
     * @var array<int,string>
     */
    private const REQUISITION_NUMERIC_COLUMNS = [
        'OrderQuantity', 'QtyShipped', 'Quantity', 'UnitCost', 'ExtendedCost',
    ];

    /**
     * Shape one detail row into the array the page renders.
     *
     * @param  array<string,mixed>  $row
     * @param  array<int,string>  $columns
     * @return array<string,mixed>
     */
    protected function deriveRequisitionRow(array $row, array $columns): array
    {
        $out = [];

        foreach ($columns as $column) {
            $out[$column] = in_array($column, self::REQUISITION_NUMERIC_COLUMNS, true)
                ? (float) ($row[$column] ?? 0)
                : ($row[$column] ?? null);
        }

        // Recorded here rather than in SQL so the table can mute a fully
        // unshipped line without the template restating the rule. A partially
        // received line still carries a commitment; that is the interesting case.
        $out['PartiallyReceived'] = ((float) ($row['QtyShipped'] ?? 0)) > 0
            && ((float) ($row['Quantity'] ?? 0)) > 0;

        return $out;
    }

    /**
     * Totals over the WHOLE filtered set, before pagination. A totals row that
     * summed only the visible page would look authoritative and be wrong.
     *
     * `requisitions` counts DISTINCT requisition numbers, not rows: a
     * requisition with nine lines is one requisition, and a card that said
     * otherwise would disagree with anything finance counts by hand.
     *
     * @param  Collection<int,array<string,mixed>>  $filtered
     * @return array<string,mixed>
     */
    protected function requisitionTotals(Collection $filtered): array
    {
        return [
            'committed' => round((float) $filtered->sum('ExtendedCost'), 2),
            'quantity' => round((float) $filtered->sum('Quantity'), 4),
            'lines' => $filtered->count(),
            'requisitions' => $filtered->pluck('RequisitionNumber')->filter()->unique()->count(),
            'vendors' => $filtered->pluck('VendorName')->filter()->unique()->count(),
            'accounts' => $filtered->pluck('AccountNumber')->filter()->unique()->count(),
            'largest' => $this->largestRequisitionLine($filtered),
        ];
    }

    /**
     * The same key set as requisitionTotals(), zeroed.
     *
     * Exists so the outage path cannot drift from the success path: a key added
     * to one and not the other is a Vue error stacked on top of an outage. The
     * unit suite asserts the two key sets are identical.
     *
     * The zeros are structural padding for a table that renders nothing. The
     * page must make the unavailability visible — flashed warning, empty table
     * — and never present "TTD 0" as an answer.
     *
     * @return array<string,mixed>
     */
    protected function emptyRequisitionTotals(): array
    {
        return [
            'committed' => 0.0,
            'quantity' => 0.0,
            'lines' => 0,
            'requisitions' => 0,
            'vendors' => 0,
            'accounts' => 0,
            'largest' => ['amount' => 0.0, 'label' => null],
        ];
    }

    /**
     * The single biggest committed line, for the KPI card's sub-label.
     *
     * @param  Collection<int,array<string,mixed>>  $filtered
     * @return array{amount:float,label:string|null}
     */
    private function largestRequisitionLine(Collection $filtered): array
    {
        $line = $filtered->sortByDesc(fn ($r) => (float) ($r['ExtendedCost'] ?? 0))->first();

        if ($line === null) {
            return ['amount' => 0.0, 'label' => null];
        }

        return [
            'amount' => round((float) ($line['ExtendedCost'] ?? 0), 2),
            'label' => $line['ItemDescription'] ?: ($line['AccountDescription'] ?: null),
        ];
    }
}
