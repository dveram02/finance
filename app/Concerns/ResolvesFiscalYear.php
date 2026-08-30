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
     * The last fiscal period to SHOW as a figure, given what has actually posted.
     *
     * resolveCutoff() answers "how much of this year has ELAPSED", which for the
     * current fiscal year includes the month we are standing in. The ledger,
     * though, carries only POSTED GL, and the in-progress month has normally not
     * posted yet: measured 2026-08-29 (fiscal period 11 = August), FY2026 held
     * 492 accounts with July activity and ZERO with August, and
     * dbo.MonthlyExpenditure emitted no August rows at all.
     *
     * Rendering that month as 0.00 asserts "nothing was spent in August" when
     * the truth is "August has not been posted yet" — the same
     * not-started-versus-real-zero distinction the dashboard makes with its
     * null-past-the-cutoff series. So for the CURRENT fiscal year the boundary
     * is the earlier of the elapsed cutoff and the last period carrying data.
     *
     * A PAST fiscal year is never capped. A completed year whose September was
     * genuinely empty must keep its 0.00 — that is a real measurement, and
     * blanking it would be inventing an absence.
     *
     * The caller must pass the UNFILTERED rows for the year: the boundary is a
     * property of the posting calendar, not of whichever department is on
     * screen, and deriving it from a filtered set would move the blanks around
     * as the user filters.
     *
     * @param  iterable<int,array<string,mixed>>  $rows
     * @param  array<int,string>  $monthKeys  month columns in PeriodID order
     */
    protected function postedCutoff(int $fiscalYear, iterable $rows, array $monthKeys): int
    {
        $elapsed = $this->resolveCutoff($fiscalYear);

        if ($fiscalYear !== $this->currentFiscalYear()) {
            return $elapsed;
        }

        $lastPopulated = 0;
        foreach ($rows as $row) {
            foreach ($monthKeys as $i => $key) {
                $period = $i + 1;
                if ($period > $lastPopulated && ((float) ($row[$key] ?? 0)) !== 0.0) {
                    $lastPopulated = $period;
                }
            }
        }

        return min($elapsed, $lastPopulated);
    }

    /**
     * The 12 fiscal-month headings with a FOUR-DIGIT year — "Oct 2025" … "Sep 2026".
     *
     * For exports, where the screen's "OCT, 25" is ambiguous out of context: a
     * fiscal year spans two calendar years, and a reader opening the file in a
     * spreadsheet months later has nothing on the row to tell them which one
     * October belongs to.
     *
     * Returned as a 0-indexed list in PeriodID order, so it lines up index for
     * index with FinanceLedger::MONTHS. Derived from fiscalMonthLabels() rather
     * than re-deriving the calendar, so there is one Oct->Sep rule.
     *
     * @return array<int,string>
     */
    protected function fiscalMonthHeadings(int $fiscalYear): array
    {
        $out = [];

        foreach ($this->fiscalMonthLabels($fiscalYear) as $periodId => $label) {
            [$abbr] = explode(', ', $label);

            // PeriodID 1-3 are Oct-Dec of the PRIOR calendar year.
            $out[] = ucfirst(strtolower($abbr)).' '.($fiscalYear - ($periodId <= 3 ? 1 : 0));
        }

        return $out;
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
     *
     * $requested is raw request input, so it is typed mixed deliberately: it may
     * be a string, null, or — from `?fy[]=x` — an array, which PHP would refuse
     * to coerce to a ?string parameter and throw on. Anything that is not a
     * four-digit string is not a fiscal year and falls through to the default.
     *
     * The regex is doing the real work, not the list lookup: (int) 'notayear'
     * is 0 and never matches an available year, but (int) '2025abc' is 2025 and
     * would otherwise be accepted as a deliberate request for FY2025.
     */
    protected function resolveFiscalYear(mixed $requested, $years, int $currentFiscalYear): ?int
    {
        if ($years->isEmpty()) {
            return $currentFiscalYear;
        }

        $available = $years->map(fn ($y) => (int) $y);

        if (is_string($requested)
            && preg_match('/^\d{4}$/', $requested)
            && $available->contains((int) $requested)) {
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
