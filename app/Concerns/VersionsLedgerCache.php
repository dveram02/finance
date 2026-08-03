<?php

namespace App\Concerns;

use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;

/**
 * Suffixes a cache key with the ledger snapshot's last refresh time, so a
 * refresh invalidates every cached filter list at once instead of leaving the
 * pages stale for the remainder of the TTL.
 *
 * Applied to ALL the ledger-backed controllers as a shared trait rather than
 * as per-controller string edits, because DashboardController deliberately
 * reuses the same `budget-allocations:years:{username}` key that
 * BudgetAllocationController writes. Versioning them independently would break
 * that sharing and double the query load.
 */
trait VersionsLedgerCache
{
    /**
     * A cache key stamped with the snapshot version.
     *
     * The probe itself is cached (config ledger.cache.version_seconds), so this
     * costs one trivial query per minute rather than one per request.
     */
    protected function ledgerCacheKey(string $key): string
    {
        return $key.':v'.$this->ledgerVersion();
    }

    /**
     * The snapshot version stamp — MAX(RefreshedAt) across all fiscal years.
     *
     * On failure this returns a constant rather than throwing or returning a
     * changing value. Throwing would turn a metadata hiccup into a page
     * outage, and a changing fallback (a timestamp, a random value) would
     * silently bypass the cache on every request and hammer the source at
     * exactly the moment it is already struggling.
     */
    protected function ledgerVersion(): string
    {
        return Cache::store(config('ledger.cache.store'))->remember(
            'finance-ledger:version',
            config('ledger.cache.version_seconds'),
            function () {
                try {
                    $row = DB::connection('FinanceAutomationSystem')
                        ->table('FinanceLedgerRefresh')
                        ->where('Outcome', 'OK')
                        ->max('RefreshedAt');

                    return $row === null ? 'none' : md5((string) $row);
                } catch (\Throwable $e) {
                    Log::warning('Finance ledger version probe failed; falling back to an unversioned cache key.', [
                        'exception' => $e->getMessage(),
                    ]);

                    return 'unknown';
                }
            }
        );
    }
}
