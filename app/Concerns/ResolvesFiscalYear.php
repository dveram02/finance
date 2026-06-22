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
