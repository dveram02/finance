<?php

namespace App\Concerns;

use Illuminate\Support\Collection;

/**
 * Pure shaping helpers for the Variance page (formerly Allocation Line
 * Expenditure) — no database, no dates, no request. The trait keeps its name
 * because the row grain it shapes is still the allocation LINE; only the page
 * was renamed. Extracted so the allocation rule itself can be tested
 * offline, the way DashboardDataTransforms is: the ledger tests skip when SQL
 * Server is unreachable, which means without this the rule would have no
 * regression net in CI at all.
 *
 * THE RULE (changed 2026-08-25, adopted from "SQL Revised Allocation Oversight
 * F"). dbo.vw_FinanceLedger computes:
 *
 *     ActualExpenditure = YTDTotal + Approved
 *     Excess            = MAX(0, YTDTotal - Allocation)
 *     AllocationBalance = MAX(0, Allocation - YTDTotal)
 *
 * Approved counts toward the reported "actual" but NOT against the balance;
 * Routing counts toward neither and is carried for information only. The
 * previous rule measured YTD + Approved + Routing against the allocation — see
 * financesqlupdate.md for the before/after and how to revert.
 *
 * Approved and Routing are therefore NOT interchangeable any more, which is why
 * the single "Encumbered" column they used to be summed into is gone: adding
 * together one figure that counts and one that does not, then displaying the
 * total next to a balance that ignores both, invited exactly the wrong reading.
 */
trait DerivesAllocationLines
{
    /**
     * Money columns read from the ledger, cast to float on the way in.
     *
     * @var array<int,string>
     */
    private const NUMERIC_COLUMNS = [
        'Allocation', 'Approved', 'Routing', 'YTDTotal',
        'ActualExpenditure', 'Excess', 'AllocationBalance',
    ];

    /**
     * Shape one ledger row into the array the page renders.
     *
     * @param  array<string,mixed>  $row
     * @param  array<int,string>  $columns
     * @return array<string,mixed>
     */
    protected function deriveAllocationLine(array $row, array $columns, array $months): array
    {
        $numeric = array_merge(self::NUMERIC_COLUMNS, $months);

        $out = [];
        foreach ($columns as $column) {
            $out[$column] = in_array($column, $numeric, true)
                ? (float) ($row[$column] ?? 0)
                : ($row[$column] ?? null);
        }

        [$out['StatusKey'], $out['StatusAmount']] = $this->classifyAllocationLine(
            (float) $out['Excess'],
            (float) $out['AllocationBalance'],
        );

        return $out;
    }

    /**
     * Classify a line from the ledger's Excess / AllocationBalance pair.
     *
     * The view floors the balance at zero and reports any overspend separately,
     * so exactly one of the two can be non-zero. Classifying from those columns
     * keeps the rule single-sourced in SQL rather than restating the arithmetic
     * here, where it could drift.
     *
     * @return array{0:string,1:float}
     */
    protected function classifyAllocationLine(float $excess, float $balance): array
    {
        // Both sides are rounded money, but comparing floats for exact equality
        // is still unsafe — half a cent of tolerance decides "fully spent".
        if ($excess >= 0.005) {
            return ['over', round($excess, 2)];
        }

        if ($balance >= 0.005) {
            return ['under', round($balance, 2)];
        }

        return ['exact', 0.0];
    }

    /**
     * Totals over the WHOLE filtered set, before pagination. A totals row that
     * summed only the visible page would look authoritative and be wrong.
     *
     * @param  Collection<int,array<string,mixed>>  $filtered
     * @return array<string,mixed>
     */
    protected function allocationTotals(Collection $filtered, array $months): array
    {
        $monthTotals = [];
        foreach ($months as $month) {
            $monthTotals[$month] = round((float) $filtered->sum($month), 2);
        }

        return [
            'allocation' => round((float) $filtered->sum('Allocation'), 2),
            'months' => $monthTotals,
            'ytd' => round((float) $filtered->sum('YTDTotal'), 2),
            // Separate, because they mean different things under the current
            // rule: Approved counts into `actual`, Routing counts into nothing.
            'approved' => round((float) $filtered->sum('Approved'), 2),
            'routing' => round((float) $filtered->sum('Routing'), 2),
            'actual' => round((float) $filtered->sum('ActualExpenditure'), 2),
            // Summed per line, NOT derived from the totals: an account that has
            // overspent contributes zero balance, and netting its overspend
            // against another account's headroom would overstate what is
            // actually available to spend.
            'balance' => round((float) $filtered->sum('AllocationBalance'), 2),
            'exceededCount' => $filtered->where('StatusKey', 'over')->count(),
        ];
    }

    /**
     * The same key set as allocationTotals(), zeroed.
     *
     * Exists so the outage path cannot drift from the success path: a key added
     * to one and not the other is a Vue error on top of an outage. The unit
     * suite asserts the two key sets are identical.
     *
     * The zeros here are structural padding for a table that renders nothing —
     * the page must make the unavailability visible (flashed warning, empty
     * table) and never present "TTD 0" as an answer.
     *
     * @return array<string,mixed>
     */
    protected function emptyAllocationTotals(array $months): array
    {
        return [
            'allocation' => 0,
            'months' => array_fill_keys($months, 0),
            'ytd' => 0,
            'approved' => 0,
            'routing' => 0,
            'actual' => 0,
            'balance' => 0,
            'exceededCount' => 0,
        ];
    }
}
