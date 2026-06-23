<?php

namespace Tests\Unit;

use App\Concerns\DashboardDataTransforms;
use App\Concerns\ResolvesFiscalYear;
use Illuminate\Support\Carbon;
use PHPUnit\Framework\Attributes\DataProvider;
use Tests\TestCase;

/**
 * Pure-transform coverage for the dashboard. These exercise the helpers in
 * ResolvesFiscalYear + DashboardDataTransforms with no SQL Server / HTTP — the
 * controller's source-availability path stays manual (no SQL-Server fake yet).
 */
class DashboardTransformsTest extends TestCase
{
    private object $h;

    protected function setUp(): void
    {
        parent::setUp();

        // Harness exposing the protected trait methods.
        $this->h = new class
        {
            use DashboardDataTransforms;
            use ResolvesFiscalYear;

            public function fiscalPeriod(): int
            {
                return $this->currentFiscalPeriod();
            }

            public function labels(int $fy): array
            {
                return $this->fiscalMonthLabels($fy);
            }

            public function cutoff(int $fy): int
            {
                return $this->resolveCutoff($fy);
            }

            public function monthly(int $fy, int $cut, array $pt): array
            {
                return $this->monthlyBarData($fy, $cut, $pt);
            }

            public function cumulative(int $cut, array $pt): array
            {
                return $this->cumulativeSeries($cut, $pt);
            }

            public function categories($rows, int $n): array
            {
                return $this->topCategories($rows, $n);
            }
        };
    }

    protected function tearDown(): void
    {
        Carbon::setTestNow();
        parent::tearDown();
    }

    // ── currentFiscalPeriod ────────────────────────────────────────────────────

    public static function fiscalPeriodCases(): array
    {
        return [
            ['2025-10-15', 1],   // October → period 1
            ['2025-12-01', 3],   // December → period 3
            ['2026-01-10', 4],   // January → period 4
            ['2026-06-22', 9],   // June → period 9
            ['2026-09-30', 12],  // September → period 12
        ];
    }

    #[DataProvider('fiscalPeriodCases')]
    public function test_current_fiscal_period_maps_oct_to_sep(string $date, int $expected): void
    {
        Carbon::setTestNow(Carbon::parse($date));

        $this->assertSame($expected, $this->h->fiscalPeriod());
    }

    // ── fiscalMonthLabels ──────────────────────────────────────────────────────

    public function test_fiscal_month_labels_match_view_format(): void
    {
        $labels = $this->h->labels(2026);

        $this->assertCount(12, $labels);
        $this->assertSame('OCT, 25', $labels[1]);   // Oct of FY-1
        $this->assertSame('JAN, 26', $labels[4]);   // Jan crosses into FY
        $this->assertSame('SEP, 26', $labels[12]);
    }

    // ── resolveCutoff ──────────────────────────────────────────────────────────

    public function test_resolve_cutoff_for_past_current_and_future_fy(): void
    {
        Carbon::setTestNow(Carbon::parse('2026-06-22'));   // current FY 2026, period 9

        $this->assertSame(12, $this->h->cutoff(2025), 'past FY → complete year');
        $this->assertSame(9, $this->h->cutoff(2026), 'current FY → current period');
        $this->assertSame(0, $this->h->cutoff(2027), 'future FY → not started');
    }

    // ── monthlyBarData ─────────────────────────────────────────────────────────

    public function test_monthly_bar_pads_missing_months_with_zero(): void
    {
        $periodTotals = [
            ['PeriodID' => 1, 'TRXPeriod' => 'OCT, 25', 'total' => 100.0],
            ['PeriodID' => 3, 'TRXPeriod' => 'DEC, 25', 'total' => 50.0],
        ];

        $out = $this->h->monthly(2026, 3, $periodTotals);

        $this->assertSame(['OCT, 25', 'NOV, 25', 'DEC, 25'], $out['labels']);
        $this->assertSame([100.0, 0.0, 50.0], $out['datasets'][0]['data']);   // Nov padded to 0
    }

    public function test_monthly_bar_is_empty_for_future_fy_cutoff_zero(): void
    {
        $out = $this->h->monthly(2027, 0, []);

        $this->assertSame([], $out['labels']);
        $this->assertSame([], $out['datasets'][0]['data']);
    }

    // ── cumulativeSeries ───────────────────────────────────────────────────────

    public function test_cumulative_series_runs_pads_gaps_and_nulls_future(): void
    {
        $periodTotals = [
            ['PeriodID' => 1, 'total' => 100.0],
            ['PeriodID' => 3, 'total' => 50.0],   // period 2 missing
        ];

        $series = $this->h->cumulative(3, $periodTotals);

        $this->assertCount(12, $series);
        $this->assertSame([100.0, 100.0, 150.0], array_slice($series, 0, 3));   // gap cumulates flat
        $this->assertNull($series[3]);                                          // months > cutoff
        $this->assertNull($series[11]);
    }

    public function test_cumulative_series_dips_on_negative_month(): void
    {
        $series = $this->h->cumulative(2, [
            ['PeriodID' => 1, 'total' => 100.0],
            ['PeriodID' => 2, 'total' => -30.0],
        ]);

        $this->assertSame([100.0, 70.0], array_slice($series, 0, 2));
    }

    // ── topCategories ──────────────────────────────────────────────────────────

    public function test_top_categories_maps_null_main_group_to_unclassified(): void
    {
        $rows = collect([
            (object) ['MainGroup' => 'Salaries', 'total' => 100.0],
            (object) ['MainGroup' => null, 'total' => 25.0],
        ]);

        $out = $this->h->categories($rows, 8);

        $this->assertContains('Unclassified', $out['labels']);
        $this->assertNotContains('Other', $out['labels']);   // both fit within the limit
    }

    public function test_top_categories_surfaces_material_negative_via_abs(): void
    {
        // B is the most material by |net| despite being negative and outside a
        // signed-DESC top-1; it must NOT be buried in Other.
        $rows = collect([
            (object) ['MainGroup' => 'A', 'total' => 10.0],
            (object) ['MainGroup' => 'B', 'total' => -500.0],
        ]);

        $out = $this->h->categories($rows, 1);

        $this->assertContains('B', $out['labels']);
        $this->assertContains('Other', $out['labels']);
        // Reconciliation: bars (incl. Other) sum to the grand total.
        $this->assertEqualsWithDelta(-490.0, array_sum($out['data']), 0.01);
    }

    public function test_top_categories_orders_whole_set_by_signed_value(): void
    {
        $rows = collect([
            (object) ['MainGroup' => 'A', 'total' => 100.0],
            (object) ['MainGroup' => 'B', 'total' => 300.0],
            (object) ['MainGroup' => 'C', 'total' => -50.0],
        ]);

        $out = $this->h->categories($rows, 3);

        $this->assertSame(['B', 'A', 'C'], $out['labels']);            // signed DESC
        $this->assertSame([300.0, 100.0, -50.0], $out['data']);
    }
}
