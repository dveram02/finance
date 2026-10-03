<?php

namespace Tests\Unit;

use App\Support\DirectoryFlag;
use PHPUnit\Framework\TestCase;

/**
 * The truth table for directory boolean flags, offline and container-free.
 *
 * This is the whole reason the helper exists: IsActive is a varchar holding
 * 'TRUE'/'FALSE', and the bare `(bool)` cast that used to read it returned
 * TRUE for the string 'FALSE', so deactivating an account in the source system
 * did not deactivate it in this application.
 */
class DirectoryFlagTest extends TestCase
{
    public function test_it_reads_the_strings_the_directory_actually_stores(): void
    {
        $this->assertTrue(DirectoryFlag::isTrue('TRUE'));

        // The one that matters. (bool) 'FALSE' is true in PHP.
        $this->assertFalse(DirectoryFlag::isTrue('FALSE'));
        // The trap itself, asserted so it is impossible to misread the point:
        // the bare cast says TRUE for the string 'FALSE'.
        $this->assertTrue((bool) 'FALSE');
    }

    public function test_it_is_case_insensitive_and_tolerates_padding(): void
    {
        foreach (['true', 'True', 'TRUE', ' TRUE ', "\tTRUE\n"] as $value) {
            $this->assertTrue(DirectoryFlag::isTrue($value), var_export($value, true));
        }

        foreach (['false', 'False', 'FALSE', ' FALSE ', "\tFALSE\n"] as $value) {
            $this->assertFalse(DirectoryFlag::isTrue($value), var_export($value, true));
        }
    }

    /**
     * The SQLite directory fake and some drivers hand back real booleans or
     * 1/0 rather than the strings, so the same helper has to be correct for
     * both. This is what lets the fix land without rewriting existing tests.
     */
    public function test_it_accepts_booleans_and_integers_too(): void
    {
        $this->assertTrue(DirectoryFlag::isTrue(true));
        $this->assertTrue(DirectoryFlag::isTrue(1));
        $this->assertTrue(DirectoryFlag::isTrue('1'));

        $this->assertFalse(DirectoryFlag::isTrue(false));
        $this->assertFalse(DirectoryFlag::isTrue(0));
        $this->assertFalse(DirectoryFlag::isTrue('0'));
    }

    /**
     * Everything unrecognised resolves to false. For an active-status flag the
     * safe failure is "locked out", never "let in".
     */
    public function test_unknown_blank_and_null_values_fail_closed(): void
    {
        foreach ([null, '', ' ', 'maybe', 'active', '2', '-1', 'NULL', [], 1.0, 0.0, 2] as $value) {
            $this->assertFalse(DirectoryFlag::isTrue($value), var_export($value, true));
        }
    }

    /**
     * The allowlist is deliberately narrower than a general boolean parser.
     * filter_var(..., FILTER_VALIDATE_BOOLEAN) - which this used until the
     * strictness pass - also accepts 'yes' and 'on'. The directory stores
     * neither, and for a flag that switches an account ON, breadth is only
     * extra ways in.
     */
    public function test_it_does_not_accept_boolean_like_words_the_directory_never_stores(): void
    {
        foreach (['yes', 'YES', 'on', 'ON', 'y', 'enabled', 'active'] as $value) {
            $this->assertFalse(DirectoryFlag::isTrue($value), var_export($value, true));
        }
    }

    /**
     * Worth pinning explicitly, because it is the operational risk in this
     * choice: if the source system ever switched to 'Y'/'N', every user would
     * be locked OUT rather than silently let in. That is the direction we want
     * to fail in — but someone would need to notice quickly, so the behaviour
     * should be a recorded decision rather than a surprise.
     */
    public function test_y_and_n_both_fail_closed_rather_than_one_granting_access(): void
    {
        $this->assertFalse(DirectoryFlag::isTrue('Y'));
        $this->assertFalse(DirectoryFlag::isTrue('N'));
        $this->assertFalse(DirectoryFlag::isTrue('T'));
        $this->assertFalse(DirectoryFlag::isTrue('F'));
    }
}
