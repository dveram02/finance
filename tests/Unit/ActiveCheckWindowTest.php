<?php

namespace Tests\Unit;

use App\Support\ActiveCheckWindow;
use PHPUnit\Framework\TestCase;

/**
 * Normalisation of the active-status trust window, offline.
 *
 * Both directions of misconfiguration are dangerous and they are dangerous
 * differently, which is why neither is reachable: a TTL of 0 would be a
 * denial of service against a remote shared auth server, and a huge TTL would
 * leave a revoked account live inside a finance application.
 */
class ActiveCheckWindowTest extends TestCase
{
    public function test_it_takes_well_formed_values(): void
    {
        $w = ActiveCheckWindow::fromConfig(120, 30);

        $this->assertSame(120, $w->ttlSeconds);
        $this->assertSame(30, $w->retrySeconds);
    }

    public function test_it_accepts_numeric_strings_from_env(): void
    {
        // Everything out of .env arrives as a string.
        $w = ActiveCheckWindow::fromConfig(' 90 ', '20');

        $this->assertSame(90, $w->ttlSeconds);
        $this->assertSame(20, $w->retrySeconds);
    }

    public function test_the_default_is_sixty_seconds(): void
    {
        $w = ActiveCheckWindow::fromConfig(null, null);

        $this->assertSame(60, $w->ttlSeconds);
        $this->assertSame(ActiveCheckWindow::DEFAULT_TTL_SECONDS, $w->ttlSeconds);
    }

    /**
     * 🔴 Zero must NOT mean "check on every request". That is not
     * secure-by-default; it is a directory round trip per page view against a
     * server shared with other applications.
     */
    public function test_zero_does_not_mean_check_every_request(): void
    {
        foreach ([0, '0', '00', -1, '-1'] as $value) {
            $w = ActiveCheckWindow::fromConfig($value, 15);

            $this->assertSame(60, $w->ttlSeconds, var_export($value, true));
            $this->assertGreaterThanOrEqual(ActiveCheckWindow::MIN_TTL_SECONDS, $w->ttlSeconds);
        }
    }

    /** A huge value must not mean "never re-check". */
    public function test_an_oversized_window_is_clamped(): void
    {
        $this->assertSame(
            ActiveCheckWindow::MAX_TTL_SECONDS,
            ActiveCheckWindow::fromConfig(99999, 15)->ttlSeconds
        );
    }

    public function test_an_undersized_window_is_clamped_up(): void
    {
        $this->assertSame(
            ActiveCheckWindow::MIN_TTL_SECONDS,
            ActiveCheckWindow::fromConfig(1, 15)->ttlSeconds
        );
    }

    public function test_garbage_falls_back_to_the_default(): void
    {
        foreach (['abc', '', ' ', '0.5', '1e2', '+60', [], true, 60.5] as $value) {
            $this->assertSame(
                60,
                ActiveCheckWindow::fromConfig($value, 15)->ttlSeconds,
                var_export($value, true)
            );
        }
    }

    public function test_the_retry_can_never_exceed_the_window(): void
    {
        // A retry longer than the window is meaningless - the window expires
        // first - so it is clamped rather than left as dead configuration.
        $w = ActiveCheckWindow::fromConfig(60, 600);

        $this->assertSame(60, $w->retrySeconds);
        $this->assertSame(0, $w->outageBackdateSeconds());
    }

    public function test_a_zero_retry_does_not_hammer_a_down_server(): void
    {
        foreach ([0, '0', -5, 'abc', null] as $value) {
            $w = ActiveCheckWindow::fromConfig(60, $value);

            $this->assertSame(ActiveCheckWindow::DEFAULT_RETRY_SECONDS, $w->retrySeconds, var_export($value, true));
        }
    }

    /**
     * The backdate is what makes the next request retry after retrySeconds
     * rather than waiting the whole window: stamping verifiedAt at
     * (now - 45s) with a 60s window leaves 15s to go.
     */
    public function test_the_outage_backdate_is_the_window_less_the_retry(): void
    {
        $this->assertSame(45, ActiveCheckWindow::fromConfig(60, 15)->outageBackdateSeconds());
        $this->assertSame(270, ActiveCheckWindow::fromConfig(300, 30)->outageBackdateSeconds());
        $this->assertSame(0, ActiveCheckWindow::fromConfig(60, 60)->outageBackdateSeconds());
    }

    public function test_there_is_no_way_to_switch_the_check_off(): void
    {
        foreach ([0, '0', null, '', 'off', 'never', -1, PHP_INT_MAX] as $value) {
            $w = ActiveCheckWindow::fromConfig($value, 15);

            $this->assertGreaterThanOrEqual(ActiveCheckWindow::MIN_TTL_SECONDS, $w->ttlSeconds);
            $this->assertLessThanOrEqual(ActiveCheckWindow::MAX_TTL_SECONDS, $w->ttlSeconds);
        }
    }
}
