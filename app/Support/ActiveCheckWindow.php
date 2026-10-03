<?php

namespace App\Support;

/**
 * How long `active.user` may trust the local mirror before re-reading the
 * directory, and how soon it retries after an outage. Normalised.
 *
 * Pure: no container, no config facade — values are passed in, so tests/Unit
 * can exercise every edge with no database. Same shape as
 * RequisitionScopeThresholds.
 *
 * FAILS CLOSED, and "closed" here needs stating because BOTH directions are
 * dangerous and they are dangerous in different ways:
 *
 *   - A TTL of 0 would mean "re-query on every single request". That is not
 *     secure-by-default, it is a denial of service against an auth server that
 *     is remote and shared with other applications.
 *   - A huge TTL would mean "effectively never re-check", leaving a revoked
 *     account live inside a finance application for as long as the session
 *     lasts.
 *
 * So neither is reachable by accident: garbage falls back to the DEFAULT, and
 * a well-formed but out-of-range number is clamped into [MIN, MAX]. There is
 * deliberately NO opt-out value — unlike the requisition row ceiling, you
 * cannot turn this check off from configuration.
 */
final class ActiveCheckWindow
{
    /**
     * 60s, lowered from 300s on 2026-10-03.
     *
     * The cost is bounded per USER, not per request or per session: the
     * timestamp lives on the `users` row, so every session and every tab that
     * user has open shares one lookup per window. At 60s that is at most one
     * directory read per active user per minute, which for a portal with a
     * handful of mapped users is nothing — and it cuts the window in which a
     * deliberately deactivated account keeps reading financial data from five
     * minutes to one.
     */
    public const DEFAULT_TTL_SECONDS = 60;

    /** Four lookups per active user per minute is the most this will ever do. */
    public const MIN_TTL_SECONDS = 15;

    /** Beyond this it is a typo, and a revoked account stays live too long. */
    public const MAX_TTL_SECONDS = 900;

    public const DEFAULT_RETRY_SECONDS = 15;

    public function __construct(
        public readonly int $ttlSeconds,
        public readonly int $retrySeconds,
    ) {}

    public static function fromConfig(mixed $ttl, mixed $retry): self
    {
        $t = self::normaliseTtl($ttl);

        return new self($t, self::normaliseRetry($retry, $t));
    }

    /**
     * How far into the past to backdate the verification stamp after a failed
     * directory read, so the NEXT request retries in retrySeconds rather than
     * waiting the full window — without re-querying a down server on every
     * request in between.
     */
    public function outageBackdateSeconds(): int
    {
        return max(0, $this->ttlSeconds - $this->retrySeconds);
    }

    /**
     * Accepted:  60, '60', ' 60 '
     * Clamped:   1 -> 15, 99999 -> 900
     * Defaulted: '+60', '-1', '0.5', '1e2', '', ' ', null, [], 'abc', 0, '0'
     *
     * Note 0 is NOT an opt-out here, unlike RequisitionScopeThresholds: zero
     * would mean a directory round trip on every request. It falls back to the
     * default like any other unusable value.
     */
    private static function normaliseTtl(mixed $value): int
    {
        if (is_int($value)) {
            return $value < 1 ? self::DEFAULT_TTL_SECONDS : self::clampTtl($value);
        }

        // Digits only after trimming. No sign branch, so '+60' and '-5' both
        // fall through; rejects floats, scientific notation, internal spaces,
        // '', null and arrays.
        if (! is_string($value) || preg_match('/^\d+$/', trim($value)) !== 1) {
            return self::DEFAULT_TTL_SECONDS;
        }

        $n = (int) trim($value);

        // '0', '00' reach here as 0 — a typo, not a request to check always.
        return $n < 1 ? self::DEFAULT_TTL_SECONDS : self::clampTtl($n);
    }

    private static function clampTtl(int $n): int
    {
        return max(self::MIN_TTL_SECONDS, min($n, self::MAX_TTL_SECONDS));
    }

    /**
     * Clamped to [1, ttl]. A retry longer than the window is meaningless (the
     * window would expire first), and a retry of 0 would re-query a server we
     * already know is down on every single request.
     */
    private static function normaliseRetry(mixed $value, int $ttl): int
    {
        $r = match (true) {
            is_int($value) => $value,
            is_string($value) && preg_match('/^\d+$/', trim($value)) === 1 => (int) trim($value),
            default => self::DEFAULT_RETRY_SECONDS,
        };

        if ($r < 1) {
            $r = self::DEFAULT_RETRY_SECONDS;
        }

        return min($r, $ttl);
    }
}
