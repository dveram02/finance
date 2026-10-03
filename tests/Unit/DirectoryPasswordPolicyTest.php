<?php

namespace Tests\Unit;

use App\Services\DirectoryPasswordService;
use PHPUnit\Framework\TestCase;

/**
 * The character-class guard, exercised at its boundaries with no container.
 *
 * This matters more than its size suggests: UserPassword is varchar COLLATE
 * Latin1_General_CI_AS and the connection sends nvarchar, so anything this
 * pattern lets through that CP1252 cannot represent is stored as '?' and locks
 * the user out of an application with no password-reset route. Keeping the
 * check offline means it is still covered on a machine with no SQL Server.
 */
class DirectoryPasswordPolicyTest extends TestCase
{
    private function allows(string $candidate): bool
    {
        return (bool) preg_match(DirectoryPasswordService::PRINTABLE_ASCII, $candidate);
    }

    public function test_it_accepts_the_printable_ascii_range(): void
    {
        $this->assertTrue($this->allows(' '));            // 0x20, the low bound
        $this->assertTrue($this->allows('~'));            // 0x7E, the high bound
        $this->assertTrue($this->allows('correct-horse-battery'));
        $this->assertTrue($this->allows('P@ssw0rd!'));
        $this->assertTrue($this->allows('has spaces in it'));

        // Every byte in the range, in one string.
        $all = implode('', array_map('chr', range(0x20, 0x7E)));
        $this->assertTrue($this->allows($all));
    }

    public function test_it_rejects_the_bytes_either_side_of_the_range(): void
    {
        $this->assertFalse($this->allows(chr(0x1F)));
        $this->assertFalse($this->allows(chr(0x7F)));
    }

    public function test_it_rejects_control_characters(): void
    {
        $this->assertFalse($this->allows("abc\tdef"));
        $this->assertFalse($this->allows("abc\ndef"));
        $this->assertFalse($this->allows("abc\rdef"));
        $this->assertFalse($this->allows("abc\0def"));
    }

    /**
     * Without /D (PCRE_DOLLAR_ENDONLY) the $ anchor matches before a trailing
     * newline, so this string passes and the guard is defeated by its own
     * anchor. This is the test that pins the modifier.
     */
    public function test_a_trailing_newline_does_not_slip_past_the_anchor(): void
    {
        $this->assertFalse($this->allows("abcdef\n"));
        $this->assertFalse($this->allows("abcdef\r\n"));
    }

    public function test_it_rejects_non_ascii_even_when_cp1252_could_represent_it(): void
    {
        // é and £ do exist in CP1252 and would round-trip today, but the
        // collation is accent-insensitive and the behaviour is collation
        // dependent. Excluding them is the cheap half of the insurance.
        $this->assertFalse($this->allows('pa'.chr(0xC3).chr(0xA9).'ssword'));
        $this->assertFalse($this->allows(chr(0xC2).chr(0xA3).'100note'));

        // A non-breaking space, which is what a paste from Word produces.
        $this->assertFalse($this->allows('abc'.chr(0xC2).chr(0xA0).'def'));
    }

    public function test_it_fails_closed_on_invalid_utf8(): void
    {
        // A lone continuation byte. preg_match returns false here rather than
        // 0 under /u; in byte mode it simply does not match. Either way the
        // password must be refused.
        $this->assertFalse($this->allows('abc'.chr(0xC3)));
    }

    public function test_it_rejects_an_empty_password(): void
    {
        $this->assertFalse($this->allows(''));
    }

    public function test_the_length_bounds_fit_inside_the_column(): void
    {
        // UserPassword is varchar(255), measured 2026-10-02.
        $this->assertGreaterThanOrEqual(1, DirectoryPasswordService::MIN_LENGTH);
        $this->assertLessThanOrEqual(255, DirectoryPasswordService::MAX_LENGTH);
        $this->assertLessThan(DirectoryPasswordService::MAX_LENGTH, DirectoryPasswordService::MIN_LENGTH);
    }
}
