<?php

namespace App\Support;

use Illuminate\Support\Carbon;

/**
 * When is a MISSING current fiscal year expected rather than a failure?
 *
 * Pure: no container, no config facade — values are passed in, so tests/Unit
 * can exercise every edge with no database. Same shape as ActiveCheckWindow
 * and RequisitionScopeThresholds.
 *
 * WHY THIS EXISTS
 *   `ledger:status` asserts that the CURRENT fiscal year has been built, and it
 *   derives the current year from the CLOCK: FY2027 begins 1 Oct 2026. But
 *   usp_RefreshFinanceLedgerSnapshotAll enumerates fiscal years FROM THE SOURCE
 *   (0098AFinGLMaster UNION 0040CBudgetsAllocation), not from a calendar range.
 *   A year that has started but holds no source rows is therefore never
 *   attempted, never logged, and — before this guard — reported as CRITICAL.
 *
 *   MEASURED 2026-10-07, one day after the parity release went live: FY2027 had
 *   0 rows in both source tables, the latest GL posting of any year was
 *   2026-08-31, and the health check said "CRITICAL: fiscal year 2027 has never
 *   been built" while the nightly Agent job had run correctly and succeeded.
 *
 * 🔴 WHY IT MATTERS MORE THAN ONE RED LINE. Left unfixed, the check alerts
 *   every day from 1 October until FY2027 data appears — possibly weeks. An
 *   alarm that cries wolf for weeks gets muted, and a muted alarm makes the
 *   REAL failure silent too. That is strictly worse than having no check, which
 *   is why this is a correctness fix and not a convenience.
 *
 * THE RULE, AND BOTH HALVES ARE LOAD-BEARING
 *   Absence is expected only when the source genuinely has nothing for that
 *   year AND the year is still young. Past the window, a dataless current year
 *   means nobody ever loaded the allocations — a real problem that would
 *   otherwise stay quiet forever, because there is nothing to go stale.
 *
 * 🔴 FAILS CLOSED, in three distinct ways, because every one of them is a way
 *   the stopped-scheduler alarm could be switched off by accident:
 *     - a NULL row count (the source probe threw) is NOT benign. "We could not
 *       establish that this is expected" must never read as "expected".
 *     - a grace of 0 disables the tolerance entirely, restoring the old
 *       unconditional CRITICAL. 0 means off, not unlimited.
 *     - a NEGATIVE age — a clock behind the fiscal year start — is not benign
 *       either. Two servers with two clocks is a documented condition of this
 *       deployment, so a backwards clock must not buy indefinite silence.
 */
final class CurrentYearGrace
{
    /**
     * Is a missing current fiscal year expected?
     *
     * @param  int|null  $sourceRows  rows the SOURCE holds for that year; null = could not be read
     * @param  int  $ageInDays  days since the fiscal year began
     * @param  int  $graceDays  how long absence is tolerated; 0 disables
     */
    public static function isExpectedlyAbsent(?int $sourceRows, int $ageInDays, int $graceDays): bool
    {
        if ($sourceRows === null || $sourceRows > 0) {
            return false;
        }

        if ($graceDays <= 0) {
            return false;
        }

        // A negative age means the clock is behind the fiscal year's start.
        // Treated as NOT expected: see the fails-closed note above.
        if ($ageInDays < 0) {
            return false;
        }

        return $ageInDays < $graceDays;
    }

    /**
     * Days elapsed since a fiscal year began.
     *
     * FY N runs 1 Oct (N-1) → 30 Sep N, so FY2027 began on 2026-10-01. Returns
     * a NEGATIVE number if `$now` precedes that date, which isExpectedlyAbsent()
     * deliberately refuses to treat as benign.
     */
    public static function ageInDays(string $fiscalYear, ?Carbon $now = null): int
    {
        $start = Carbon::create((int) $fiscalYear - 1, 10, 1)->startOfDay();

        return (int) $start->diffInDays($now ?? Carbon::now(), false);
    }
}
