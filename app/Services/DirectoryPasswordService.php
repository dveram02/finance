<?php

namespace App\Services;

use App\Models\User;
use App\Support\DirectoryFlag;
use Illuminate\Contracts\Database\Query\Expression;
use Illuminate\Database\Connection;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;
use Illuminate\Support\Str;
use Illuminate\Validation\ValidationException;

/**
 * Changes a user's password in the SWRHAExpenseControl staff directory.
 *
 * This is the ONLY write this application performs. Everything else in the
 * portal is read-only, and every other pre-existing table on that server
 * remains off limits — the carve-out is four columns on one table, for the
 * authenticated user's own row, keyed on its primary key.
 *
 * Three constraints shape the whole class, none of them obvious:
 *
 *   1. The password column is PLAINTEXT. The source system owns it and reads
 *      it as plaintext, so this application cannot hash what other systems
 *      must be able to read. hash_equals() is the available mitigation.
 *
 *   2. UserPassword is varchar COLLATE Latin1_General_CI_AS. The collation is
 *      case- AND accent-insensitive, so the password must never be compared in
 *      a SQL predicate — `WHERE UserPassword = ?` would accept 'Secret1' for
 *      'secret1' while login, which compares in PHP, would then reject it.
 *
 *   3. UserName has no unique index and the collation folds case, so
 *      'ffiguera1' matches 'FFIGUERA1'. An UPDATE keyed on UserName could
 *      therefore rewrite a DIFFERENT PERSON's password. Everything is keyed on
 *      LineID, and an ambiguous match is refused rather than resolved.
 */
class DirectoryPasswordService
{
    private const CONNECTION = 'SWRHAExpenseControl';

    private const TABLE = '0006AWebAppControls';

    /**
     * The character class a new password must match, as a preg pattern.
     *
     * Printable ASCII only (0x20 space .. 0x7E tilde), and this is a
     * CORRECTNESS guard rather than a style rule: UserPassword is varchar
     * COLLATE Latin1_General_CI_AS while the connection sends nvarchar, so any
     * codepoint outside CP1252 is silently replaced with '?' on assignment, and
     * the user is then permanently locked out of an application that has no
     * password-reset route. 0x20-0x7E is byte-identical across UTF-8, UTF-16
     * and CP1252, so under this restriction the conversion is provably
     * lossless.
     *
     * /D (PCRE_DOLLAR_ENDONLY) is load-bearing: without it a trailing
     * newline slips past the $ anchor, which is exactly what this exists
     * to exclude. No /u - the check is on BYTES, which is what is meant,
     * and invalid UTF-8 then fails closed without relying on preg_match()
     * returning false.
     */
    public const PRINTABLE_ASCII = '/^[\x20-\x7E]+$/D';

    public const MIN_LENGTH = 6;

    public const MAX_LENGTH = 64;

    // =========================================================================
    // Availability
    // =========================================================================

    public function isEnabled(): bool
    {
        return (bool) config('auth.directory_password_change', false);
    }

    // =========================================================================
    // change() — verify the current password, then write the new one
    // =========================================================================

    /**
     * @throws ValidationException on every expected failure, keyed to the form
     *                             field the user has to correct. Unexpected
     *                             throwables are logged and converted too: a
     *                             missing GRANT or a dead SQL Server must not
     *                             reach the user as a 500 page.
     */
    public function change(User $user, string $currentPassword, string $newPassword): void
    {
        if (! $this->isEnabled()) {
            throw ValidationException::withMessages([
                'current_password' => 'Password changes are not available at the moment.',
            ]);
        }

        $connection = $this->connection();

        try {
            $connection->transaction(function () use ($connection, $user, $currentPassword, $newPassword) {
                $row = $this->resolveControlRow($connection, $user);

                // Re-checked here as well as by the active.user middleware, whose
                // answer can be up to five minutes stale. Deliberately belt and
                // braces on the one path that WRITES: the middleware decides whether
                // you may look at a page, this decides whether you may change a
                // credential. DirectoryFlag, never a (bool) cast - IsActive is a
                // varchar holding 'TRUE'/'FALSE' and (bool) 'FALSE' is true in PHP.
                if (! DirectoryFlag::isTrue($row->IsActive)) {
                    throw ValidationException::withMessages([
                        'current_password' => 'Your account is not active. Please contact an administrator.',
                    ]);
                }

                if (! hash_equals((string) $row->UserPassword, $currentPassword)) {
                    throw ValidationException::withMessages([
                        'current_password' => 'Your current password is incorrect.',
                    ]);
                }

                $this->writePassword($connection, $row, $user, $newPassword);
            });
        } catch (ValidationException $e) {
            throw $e;
        } catch (\Throwable $e) {
            Log::error('Directory password change failed.', [
                'username' => $user->username,
                'exception' => $e->getMessage(),
            ]);

            throw ValidationException::withMessages([
                'current_password' => 'Your password could not be changed right now. Please try again later.',
            ]);
        }

        $this->rotateRememberToken($user);

        // Username and outcome only. A password-match oracle written to
        // laravel.log on every attempt lived in this codebase until
        // 2026-08-05; never log the old value, the new value, or whether the
        // comparison succeeded.
        Log::info('Directory password changed.', ['username' => $user->username]);
    }

    // =========================================================================
    // Internals
    // =========================================================================

    private function connection(): Connection
    {
        return DB::connection(self::CONNECTION);
    }

    /**
     * The single read that serves every job: the ambiguity guard, the active
     * check, the current-password check, and the key the UPDATE is written
     * against. One round trip to a remote, shared auth server.
     */
    private function resolveControlRow(Connection $connection, User $user): object
    {
        $rows = $connection->table(self::TABLE)
            ->where('UserName', $user->username)
            ->get(['LineID', 'UserName', 'UserPassword', 'IsActive']);

        if ($rows->count() !== 1) {
            Log::error('Directory password change refused: ambiguous or missing control row.', [
                'username' => $user->username,
                'matches' => $rows->count(),
            ]);

            // Deliberately generic. "Duplicate account" would leak the shape of
            // a directory this application does not own.
            throw ValidationException::withMessages([
                'current_password' => 'Your password could not be changed. Please contact an administrator.',
            ]);
        }

        return $rows->first();
    }

    private function writePassword(Connection $connection, object $row, User $user, string $newPassword): void
    {
        ['date' => $date, 'time' => $time] = $this->editStamp($connection);

        $affected = $connection->table(self::TABLE)
            ->where('LineID', $row->LineID)
            ->update([
                'UserPassword' => $newPassword,
                // The directory stores a display name here, not a username —
                // the existing rows read "FRANCIS FIGUERA", which is exactly
                // vw_WebAppUsers.EmployeeName, and users.name mirrors that.
                'LastEditedBy' => $user->name,
                'DateEdited' => $date,
                'TimeEdited' => $time,
            ]);

        // Read back inside the transaction. The column is varchar with a Latin1
        // collation and this password is the only way into the account: if the
        // stored bytes are not what we sent, roll back rather than lock someone
        // out of a system with no reset path. The printable-ASCII validation
        // rule makes the conversion lossless today; this is what keeps it safe
        // if the column, collation or connection encoding ever changes.
        $stored = (string) $connection->table(self::TABLE)
            ->where('LineID', $row->LineID)
            ->value('UserPassword');

        if ($affected !== 1 || ! hash_equals($stored, $newPassword)) {
            Log::error('Directory password change did not verify; rolling back.', [
                'username' => $user->username,
                'affected' => $affected,
            ]);

            // Throwing inside the transaction closure is what rolls the write
            // back. The outer catch turns this into a user-facing message.
            throw new \RuntimeException('Directory password update did not verify.');
        }
    }

    /**
     * The audit stamp has to come from the DATABASE server's clock: the web and
     * database servers are separate machines, and the ledger refresh stamps
     * with SYSDATETIME() for the same reason.
     *
     * The sqlite branch exists because the directory is faked with in-memory
     * SQLite in the test suite, which has no SYSDATETIME(). Stubbing this
     * service in those tests instead would leave the one write in the whole
     * application with no coverage.
     *
     * time(0), not the column's full time(7), for two reasons. The table is
     * owned by another team and every pre-existing row is whole-second
     * (10:52:00), so matching the incumbent convention is the conservative
     * choice when writing into someone else's schema. And the two branches
     * otherwise disagree: SQLite's time() yields HH:MM:SS while an uncast
     * SYSDATETIME() yields 15:09:55.7999153, so the assertion in
     * PasswordChangeTest only passed because the suite never saw the SQL
     * Server form. Sub-second precision buys nothing on an audit stamp the
     * source system writes to the minute.
     *
     * @return array{date: Expression, time: Expression}
     */
    private function editStamp(Connection $connection): array
    {
        return $connection->getDriverName() === 'sqlite'
            ? ['date' => DB::raw("date('now','localtime')"), 'time' => DB::raw("time('now','localtime')")]
            : ['date' => DB::raw('CAST(SYSDATETIME() AS date)'), 'time' => DB::raw('CAST(SYSDATETIME() AS time(0))')];
    }

    /**
     * Remember-me cookies authenticate on users.remember_token alone and never
     * consult the password (see SWRHAUserProvider::retrieveByToken), so without
     * this a cookie issued under the OLD password would keep working forever.
     * Rotating it invalidates every remember-me cookie for the account, which
     * is the intended behaviour. The CURRENT session is unaffected — it is
     * carried by the session cookie, which the controller regenerates — but
     * this browser's own remember-me cookie dies with the rest, so the user
     * will have to tick the box again at their next sign-in. That is the
     * fail-secure direction and is deliberate.
     *
     * users.password is deliberately left alone — it holds a random hash,
     * nothing authenticates against it, and syncing it would create a second
     * divergent copy of a credential.
     */
    private function rotateRememberToken(User $user): void
    {
        $user->forceFill(['remember_token' => Str::random(60)])->save();
    }
}
