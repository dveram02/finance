<?php

namespace Tests\Unit;

use App\Support\CurrentYearGrace;
use Illuminate\Support\Carbon;
use PHPUnit\Framework\TestCase;

/**
 * The rule that keeps `ledger:status` from crying wolf every October.
 *
 * FULLY OFFLINE — no container, no database. CurrentYearGrace is pure for
 * exactly this reason: the behaviour it governs is a health check that alerts
 * on a cron, so the edges have to be exercisable without the SQL Server that
 * the command itself needs.
 *
 * Context: `ledger:status` derives the current fiscal year from the clock,
 * while the refresh enumerates fiscal years from the SOURCE. A year that has
 * started but holds no source rows is never built, and before this guard that
 * read as CRITICAL — measured 2026-10-07 on production, one day after go-live,
 * with the nightly job working perfectly.
 */
class CurrentYearGraceTest extends TestCase
{
    // =========================================================================
    // The benign case — the one this guard exists for
    // =========================================================================

    public function test_a_dataless_brand_new_fiscal_year_is_expected(): void
    {
        // The production case: FY2027, six days old, nothing in the source.
        $this->assertTrue(CurrentYearGrace::isExpectedlyAbsent(0, 6, 90));
    }

    public function test_it_is_still_expected_on_the_first_day_of_the_year(): void
    {
        $this->assertTrue(CurrentYearGrace::isExpectedlyAbsent(0, 0, 90));
    }

    // =========================================================================
    // The cases that must STILL alarm
    // =========================================================================

    public function test_a_dataless_year_past_the_grace_window_is_a_failure(): void
    {
        // By now it means nobody ever loaded the allocations — a real problem
        // that would otherwise stay quiet forever, because a year that was
        // never built has nothing to go stale.
        $this->assertFalse(CurrentYearGrace::isExpectedlyAbsent(0, 90, 90));
        $this->assertFalse(CurrentYearGrace::isExpectedlyAbsent(0, 200, 90));
    }

    public function test_a_year_with_source_data_is_never_expected_to_be_absent(): void
    {
        // The source has rows, so the refresh should have built it. This is the
        // genuine "the scheduler is not running" case and must never be excused.
        $this->assertFalse(CurrentYearGrace::isExpectedlyAbsent(1, 1, 90));
        $this->assertFalse(CurrentYearGrace::isExpectedlyAbsent(50_000, 1, 90));
    }

    /**
     * 🔴 The most important case in this file.
     *
     * A null row count means the source probe THREW. Treating that as "the year
     * is legitimately empty" would let a connection blip switch off the
     * stopped-scheduler alarm — the single failure this command exists to
     * catch. "Could not establish that this is benign" must read as NOT benign.
     */
    public function test_an_unreadable_source_is_not_benign(): void
    {
        $this->assertFalse(CurrentYearGrace::isExpectedlyAbsent(null, 1, 90));
        $this->assertFalse(CurrentYearGrace::isExpectedlyAbsent(null, 0, 3650));
    }

    public function test_a_grace_of_zero_restores_the_unconditional_failure(): void
    {
        // 0 means OFF, not unlimited — the documented way to get the old
        // behaviour back without editing code.
        $this->assertFalse(CurrentYearGrace::isExpectedlyAbsent(0, 0, 0));
        $this->assertFalse(CurrentYearGrace::isExpectedlyAbsent(0, 1, 0));
    }

    public function test_a_negative_grace_is_treated_as_off_not_as_unlimited(): void
    {
        $this->assertFalse(CurrentYearGrace::isExpectedlyAbsent(0, 1, -30));
    }

    /**
     * Two servers with two clocks is a documented condition of this deployment
     * (the web box compares now() against the DB box's SYSDATETIME()). A clock
     * behind the fiscal year's start must not buy indefinite silence.
     */
    public function test_a_clock_behind_the_fiscal_year_start_is_not_benign(): void
    {
        $this->assertFalse(CurrentYearGrace::isExpectedlyAbsent(0, -1, 90));
        $this->assertFalse(CurrentYearGrace::isExpectedlyAbsent(0, -400, 90));
    }

    // =========================================================================
    // The boundary — asserted on both sides, because off-by-one here means
    // either a day of false alarm or a day of false silence
    // =========================================================================

    public function test_the_grace_boundary_is_exclusive(): void
    {
        $this->assertTrue(CurrentYearGrace::isExpectedlyAbsent(0, 89, 90), 'day 89 is inside');
        $this->assertFalse(CurrentYearGrace::isExpectedlyAbsent(0, 90, 90), 'day 90 is outside');
    }

    // =========================================================================
    // Fiscal year arithmetic — FY N begins 1 Oct (N-1)
    // =========================================================================

    public function test_age_is_zero_on_the_first_day_of_the_fiscal_year(): void
    {
        $this->assertSame(0, CurrentYearGrace::ageInDays('2027', Carbon::create(2026, 10, 1, 9)));
    }

    public function test_age_counts_from_the_first_of_october_of_the_prior_year(): void
    {
        // The real measurement: 2026-10-07 is six days into FY2027.
        $this->assertSame(6, CurrentYearGrace::ageInDays('2027', Carbon::create(2026, 10, 7, 11)));
        $this->assertSame(31, CurrentYearGrace::ageInDays('2027', Carbon::create(2026, 11, 1)));
    }

    public function test_age_is_negative_before_the_fiscal_year_begins(): void
    {
        // 30 Sep 2026 is still FY2026, so FY2027 has not started.
        $this->assertLessThan(0, CurrentYearGrace::ageInDays('2027', Carbon::create(2026, 9, 30)));
    }

    public function test_the_october_boundary_matches_the_apps_own_fiscal_year_rule(): void
    {
        // ResolvesFiscalYear: month >= 10 ? year + 1 : year. So on 2026-10-01
        // the current FY is 2027 and it is zero days old — the two must agree,
        // or the command would measure grace against the wrong year.
        $oct1 = Carbon::create(2026, 10, 1);
        $currentFy = (string) ($oct1->month >= 10 ? $oct1->year + 1 : $oct1->year);

        $this->assertSame('2027', $currentFy);
        $this->assertSame(0, CurrentYearGrace::ageInDays($currentFy, $oct1));
    }
}
