<?php

namespace App\Concerns;

/**
 * Pure data-shaping helpers for the dashboard charts — no DB access and no date
 * logic beyond the FY/cutoff passed in. Kept out of the controller body and the
 * fiscal-year trait so they can be unit-tested in isolation.
 *
 * Both monthlyBarData() and cumulativeSeries() assume $cutoff is in 0..12
 * (guaranteed by ResolvesFiscalYear::resolveCutoff()).
 */
trait DashboardDataTransforms
{
    /**
     * Non-cumulative per-month series, padded across periods 1..$cutoff so a
     * month with no rows still shows a 0 bar (keeps the x-axis uniform).
     *
     * @param  array<int,array{PeriodID:int,TRXPeriod:string,total:float}>  $periodTotals
     */
    protected function monthlyBarData(int $fiscalYear, int $cutoff, array $periodTotals): array
    {
        $labels = $this->fiscalMonthLabels($fiscalYear);   // from ResolvesFiscalYear

        $byPid = [];
        foreach ($periodTotals as $row) {
            $byPid[$row['PeriodID']] = $row['total'];
        }

        $outLabels = [];
        $data = [];
        for ($pid = 1; $pid <= $cutoff; $pid++) {
            $outLabels[] = $labels[$pid];
            $data[] = round($byPid[$pid] ?? 0.0, 2);
        }

        return [
            'labels' => $outLabels,
            'datasets' => [['label' => 'Expenditure (TTD)', 'data' => $data]],
        ];
    }

    /**
     * 12-element cumulative running total in PeriodID order. Months 1..$cutoff
     * carry the running sum (missing months cumulate as 0); months beyond $cutoff
     * are null (future — leaves a gap so the burn-up line ends at the cutoff).
     *
     * @param  array<int,array{PeriodID:int,total:float}>  $periodTotals
     * @return array<int,float|null>
     */
    protected function cumulativeSeries(int $cutoff, array $periodTotals): array
    {
        $byPid = [];
        foreach ($periodTotals as $row) {
            $byPid[$row['PeriodID']] = $row['total'];
        }

        $series = [];
        $running = 0.0;
        for ($pid = 1; $pid <= 12; $pid++) {
            if ($pid <= $cutoff) {
                $running += $byPid[$pid] ?? 0.0;
                $series[] = round($running, 2);
            } else {
                $series[] = null;
            }
        }

        return $series;
    }

    /**
     * Top categories for the horizontal bar. Selects by materiality (|net|) so a
     * large negative correction isn't buried in Other; folds the remainder into a
     * single Other; then sorts the whole set (incl. Other) by signed value so the
     * bar reads cleanly top→bottom. null/blank MainGroup → 'Unclassified'.
     */
    protected function topCategories($rows, int $limit): array
    {
        $byLabel = $rows
            ->groupBy(fn ($r) => $r->MainGroup ?: 'Unclassified')
            ->map(fn ($g) => (float) $g->sum(fn ($r) => (float) $r->total));

        $top = $byLabel->sortByDesc(fn ($v) => abs($v))->take($limit);
        $rest = (float) $byLabel->diffKeys($top)->sum();

        $final = $top->all();   // [label => value]
        if ($byLabel->count() > $limit) {
            $final['Other'] = round($rest, 2);
        }

        // Order the whole set (Other included) by signed value for a clean bar.
        arsort($final);

        return [
            'labels' => array_keys($final),
            'data' => array_values($final),
        ];
    }
}
