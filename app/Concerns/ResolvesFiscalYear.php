<?php

namespace App\Concerns;

trait ResolvesFiscalYear
{
    /**
     * The fiscal year for today. A fiscal year runs Oct 1 → Sep 30 and is
     * named for the calendar year it ends in (e.g. Oct 2025 – Sep 2026 = 2026).
     */
    protected function currentFiscalYear(): int
    {
        $now = now();

        return $now->month >= 10 ? $now->year + 1 : $now->year;
    }

    /**
     * The fiscal period (1–12) for today. PeriodID 1 = October … 12 = September,
     * matching dbo.MonthlyExpenditure. Oct–Dec → month-9; Jan–Sep → month+3.
     */
    protected function currentFiscalPeriod(): int
    {
        $month = now()->month;

        return $month >= 10 ? $month - 9 : $month + 3;
    }

    /**
     * The 12 fiscal-month labels for a year, matching the view's TRXPeriod format
     * ("OCT, 25"). PeriodID 1 = Oct of (FY-1) … 12 = Sep of FY. Generated (not read
     * from data) so the burn-up axis can show future months that have no rows yet.
     *
     * @return array<int,string> keyed by PeriodID 1..12, in period order
     */
    protected function fiscalMonthLabels(int $fiscalYear): array
    {
        $map = [
            1 => ['OCT', $fiscalYear - 1], 2 => ['NOV', $fiscalYear - 1], 3 => ['DEC', $fiscalYear - 1],
            4 => ['JAN', $fiscalYear],     5 => ['FEB', $fiscalYear],     6 => ['MAR', $fiscalYear],
            7 => ['APR', $fiscalYear],     8 => ['MAY', $fiscalYear],     9 => ['JUN', $fiscalYear],
            10 => ['JUL', $fiscalYear],     11 => ['AUG', $fiscalYear],     12 => ['SEP', $fiscalYear],
        ];

        $labels = [];
        foreach ($map as $pid => [$abbr, $year]) {
            $labels[$pid] = $abbr.', '.substr((string) $year, -2);
        }

        return $labels;
    }

    /**
     * The last fiscal period to include for a displayed FY:
     *   past FY    → 12 (complete year)
     *   current FY → current fiscal period (months elapsed so far)
     *   future FY  → 0  (not started — nothing elapsed)
     * Always clamped to 0..12 so downstream transforms can trust the range.
     */
    protected function resolveCutoff(int $fiscalYear): int
    {
        $current = $this->currentFiscalYear();

        if ($fiscalYear < $current) {
            return 12;
        }
        if ($fiscalYear > $current) {
            return 0;
        }

        return max(0, min(12, $this->currentFiscalPeriod()));
    }

    /**
     * Pick the fiscal year to display: the requested one if it has data,
     * otherwise the current FY if present, otherwise the latest FY with data.
     */
    protected function resolveFiscalYear(?string $requested, $years, int $currentFiscalYear): ?int
    {
        if ($years->isEmpty()) {
            return $currentFiscalYear;
        }

        $available = $years->map(fn ($y) => (int) $y);

        if ($requested !== null && $available->contains((int) $requested)) {
            return (int) $requested;
        }

        if ($available->contains($currentFiscalYear)) {
            return $currentFiscalYear;
        }

        return (int) $available->max();
    }

    /**
     * Previous / next fiscal years that have data, relative to the active one.
     */
    protected function fiscalYearNav(?int $activeFiscalYear, $years): array
    {
        $available = $years->map(fn ($y) => (int) $y)->sort()->values();
        $index = $available->search($activeFiscalYear, true);

        if ($index === false) {
            return ['prev' => null, 'next' => null];
        }

        return [
            'prev' => $index > 0 ? $available[$index - 1] : null,
            'next' => $index < $available->count() - 1 ? $available[$index + 1] : null,
        ];
    }
}
