<?php

namespace App\Support;

/**
 * Reads a boolean flag out of the SWRHAExpenseControl directory.
 *
 * Those flags are NOT bits. `IsActive` on dbo.0006AWebAppControls (and on
 * 0006CWebAppPostControls) is `varchar(255)` holding the literal strings
 * 'TRUE' and 'FALSE' — confirmed against the live driver, which hands PHP back
 * the string 'TRUE' — and in PHP every non-empty string except '0' is truthy,
 * so `(bool) 'FALSE'` is `true`. Three call sites did exactly that until
 * 2026-10-03, which meant deactivating an account in the source system did not
 * deactivate it here. Nothing had broken only because every production row was
 * 'TRUE' and the flag had never actually been used.
 *
 * Deleting a row still worked (the caller's own null handling caught it),
 * which is why it went unnoticed; setting the flag did not.
 *
 * Every read of a directory boolean goes through here. Do not reintroduce a
 * bare `(bool)` cast on one of these columns, and do not add a second parsing
 * helper beside this one.
 */
class DirectoryFlag
{
    /**
     * The only representations that mean TRUE. Compared after trimming and
     * upper-casing, so 'true', ' TRUE ' and 'True' all match.
     */
    private const TRUTHY_STRINGS = ['TRUE', '1'];

    /**
     * Resolve a directory flag to a real boolean against a STRICT allowlist.
     *
     * This is an authorization flag, so it is an allowlist rather than a
     * general-purpose boolean parser. An earlier revision used
     * `filter_var(..., FILTER_VALIDATE_BOOLEAN)`, which also accepts 'yes' and
     * 'on' — values this directory never stores. Breadth buys nothing here and
     * widens the set of inputs that can switch an account on, so the accepted
     * set is exactly:
     *
     *   - the boolean `true`
     *   - the integer `1`
     *   - the strings 'TRUE' and '1', case-insensitive, surrounding whitespace
     *     trimmed
     *
     * The integer and '1' are kept because the SQLite directory fake and some
     * drivers return those rather than the strings; that is what lets the same
     * helper be correct against the live directory and against the test suite.
     *
     * EVERYTHING else is FALSE — null, '', 'yes', 'on', 'Y', 'N', 'T', 'F',
     * '2', 1.0, arrays, arbitrary text. For an active-status flag the safe
     * failure is "locked out", never "let in". Note the corollary, because it
     * is a real operational risk rather than a theoretical one: if the source
     * system ever switched to 'Y'/'N', every user would be locked OUT rather
     * than silently granted access. That is the direction to fail in, but it
     * would need noticing quickly.
     */
    public static function isTrue(mixed $value): bool
    {
        if (is_bool($value)) {
            return $value;
        }

        if (is_int($value)) {
            return $value === 1;
        }

        if (! is_string($value)) {
            return false;
        }

        return in_array(strtoupper(trim($value)), self::TRUTHY_STRINGS, true);
    }
}
