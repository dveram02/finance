<?php

namespace App\Support;

/**
 * Bounded-fetch thresholds for the two requisition detail pages, normalised.
 *
 * Pure: no container, no config facade — values are passed in, so tests/Unit
 * can exercise every edge with no database. See routingupdate.md §6.5.
 *
 * FAILS CLOSED. An earlier draft normalised with max(0, …), which mapped a
 * negative or garbage value to 0 — and 0 means UNBOUNDED, so a typo in .env
 * silently disabled the memory guard. Anything invalid now falls back to the
 * DEFAULT, never to "no limit".
 */
final class RequisitionScopeThresholds
{
    public const DEFAULT_CEILING = 25000;

    /**
     * An ABSOLUTE PARSER BOUND — not a certified-safe operating value.
     *
     * Its job is narrow: stop a typo or a hostile value producing an absurd
     * LIMIT or overflowing $ceiling + 1. It is NOT a statement that 50,000 rows
     * is safe to serve, and nothing has measured that.
     *
     * Why 50,000: the only concurrency arithmetic that exists models the
     * DEFAULT request (~172 MB peak at 25,001 rows, measured 2026-10-01 on
     * CLI through the full pipeline). At the measured marginal ~5.3 KB/row,
     * 150,000 rows is ~875 MB per request — ten concurrent would be ~8.75 GB
     * on a 16 GB VM that also runs MySQL and the OS. 50,000 is ~300 MB, so ten
     * concurrent is ~3 GB: defensible under the arithmetic that was actually
     * done, and still ~2.6x the largest real single year (18,945).
     *
     * RAISING EITHER THIS OR THE CONFIGURED CEILING REQUIRES NEW MEASUREMENTS:
     * the web-SAPI memory_limit and a concurrency model for the larger request
     * size. Do not infer one from the other.
     *
     * NOTE the default (25,000) is not a memory limit at all — memory would
     * allow far more (4096M on production). It is a USABILITY limit: 93,336
     * rows is a ~5.1 s response and 3,734 pages of 25.
     */
    public const MAX_CEILING = 50000;

    public function __construct(
        public readonly int $ceiling,
        public readonly int $warnAt,
    ) {}

    public static function fromConfig(mixed $ceiling, mixed $warnAt): self
    {
        $c = self::normaliseCeiling($ceiling);

        return new self($c, self::normaliseWarn($warnAt, $c));
    }

    /**
     * Only EXACT integer 0 (or the string "0") disables the guard. Everything
     * else that is not a clean positive integer falls back to the default.
     *
     * is_numeric() + (int) is not enough, and that gap is the point: '0.5',
     * '-0.5', '00', '1e-9' and ' ' are all numeric-or-castable and all
     * truncate to 0 — which would read as "disable the guard" rather than
     * "nonsense, use the default".
     *
     * Accepted:  25000, '25000', ' 25000 '  (SURROUNDING whitespace is trimmed)
     * Opt-out:   0, '0'                      (exact, and the ONLY opt-out)
     * Defaulted: '+25000', '-1', '0.5', '00', '1e5', '', ' ', null, [], 'abc'
     */
    private static function normaliseCeiling(mixed $value): int
    {
        if ($value === 0 || $value === '0') {
            return 0;                                   // the ONLY opt-out
        }

        if (is_int($value)) {
            return $value < 0 ? self::DEFAULT_CEILING : min($value, self::MAX_CEILING);
        }

        // Strict: digits only, after trimming. A SIGN is not accepted — ^\d+$
        // has no sign branch, so '+25000' and '-5' both fall through to the
        // default. Rejects floats ('0.5'), scientific notation ('1e5'),
        // internal spaces, '', null and arrays.
        if (! is_string($value) || preg_match('/^\d+$/', trim($value)) !== 1) {
            return self::DEFAULT_CEILING;
        }

        $n = (int) trim($value);

        // '00', '000' etc. reach here as 0 — a typo, not an opt-out.
        return $n <= 0 ? self::DEFAULT_CEILING : min($n, self::MAX_CEILING);
    }

    private static function normaliseWarn(mixed $value, int $ceiling): int
    {
        if ($ceiling === 0) {
            return 0;                                   // guard off -> warnings off
        }

        $w = match (true) {
            is_int($value) => max(0, $value),
            is_string($value) && preg_match('/^\d+$/', trim($value)) === 1 => (int) trim($value),
            default => 0,                               // unparseable -> no warning
        };

        // A warn at or above the ceiling can never fire (the ceiling refuses
        // first), so it is clamped rather than left as dead configuration.
        return $w >= $ceiling ? (int) ($ceiling * 0.8) : $w;
    }
}
