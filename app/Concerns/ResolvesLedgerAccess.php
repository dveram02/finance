<?php

namespace App\Concerns;

use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;

/**
 * Answers one question: does this user map to any department at all?
 *
 * Every page in this application is scoped through dbo.vw_WebAppUserAccess,
 * which resolves a user to (ResponsibilityID, DepartmentID) pairs via the
 * SWRHAExpenseControl control tables. A user whose position has no active
 * mapping resolves to nothing, so every page is legitimately empty.
 *
 * That state has to be told apart from the other two, because all three look
 * identical in a table and mean completely different things:
 *
 *   1. the source is unavailable  -> "try again later" (something is broken)
 *   2. the user has NO mapping    -> "contact an administrator" (nothing is broken,
 *                                     and no amount of retrying or re-filtering helps)
 *   3. the user has a mapping but
 *      no rows match              -> "no results" (adjust the filters)
 *
 * Without (2), a user with no mapping is shown either a fake outage or a
 * phantom filter problem, and will chase whichever one they are told.
 *
 * This is deliberately an EXPLICIT probe rather than inferring "no access" from
 * an empty fiscal-year list: a mapped department that genuinely has no ledger
 * rows produces the same empty list, and it deserves the "no results" copy, not
 * an instruction to go and ask for permissions it already has.
 */
trait ResolvesLedgerAccess
{
    /**
     * Whether the user maps to at least one department.
     *
     * Cached briefly per user. The TTL is deliberately much shorter than the
     * filter-list caches: vw_WebAppUserAccess is a LIVE view precisely so a
     * permission change takes effect immediately, and caching this for ten
     * minutes would hand back most of that. The probe is a COUNT over two small
     * control tables, so a short TTL is cheap.
     *
     * Not wrapped in try/catch: every caller already runs inside the try that
     * renders its "source unavailable" state, and that is the correct outcome —
     * if the probe cannot run, we genuinely do not know whether the user has
     * access, and must not claim they have none.
     */
    protected function userHasLedgerAccess(string $username): bool
    {
        return (bool) Cache::store(config('ledger.cache.store'))->remember(
            "finance-ledger:access:{$username}",
            config('ledger.cache.version_seconds'),
            fn () => DB::connection('FinanceAutomationSystem')
                ->table('vw_WebAppUserAccess')
                ->where('UserName', $username)
                ->exists()
        );
    }
}
