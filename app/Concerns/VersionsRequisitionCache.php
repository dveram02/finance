<?php

namespace App\Concerns;

use Illuminate\Support\Facades\Cache;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Log;

/**
 * The requisition-detail counterpart of VersionsLedgerCache.
 *
 * WHY THIS IS NOT ledgerCacheKey(). The two snapshots are built by two STEPS of
 * one Agent job, and Agent steps cannot share a transaction: step 1 can succeed
 * while step 2 fails. Versioning these pages against FinanceLedgerRefresh would
 * then advance the cache version while the requisition data had not moved —
 * invalidating the filter lists at exactly the wrong moment, and (worse) NOT
 * invalidating them when step 2 succeeds after a step 1 abort. Different table,
 * different version stamp.
 *
 * dbo.FinanceRequisitionRefresh is RUN-KEYED, not year-keyed: one appended row
 * per execution, never updated. So "fresh" is the newest row with Outcome = OK,
 * not a per-year lookup — an aborted run appends an ABORTED row while the
 * previous snapshot stands, and the version must keep pointing at the run that
 * actually produced the data being served.
 */
trait VersionsRequisitionCache
{
    /**
     * A cache key stamped with the requisition snapshot's version.
     */
    protected function requisitionCacheKey(string $key): string
    {
        return $key.':v'.$this->requisitionVersion();
    }

    /**
     * Version stamp — a hash of the last GOOD run's RefreshedAt.
     *
     * On failure this returns a constant, for the same reason
     * VersionsLedgerCache does: throwing turns a metadata hiccup into a page
     * outage, and a changing fallback bypasses the cache on every request and
     * hammers the source exactly when it is already struggling.
     */
    protected function requisitionVersion(): string
    {
        $refreshedAt = $this->requisitionRefreshedAt();

        return $refreshedAt === null ? 'none' : md5($refreshedAt);
    }

    /**
     * The last GOOD requisition refresh time, as the raw string the database
     * holds it in, or null when it has never built (or cannot be read).
     *
     * Cached for the same short window as the ledger version probe, since it
     * gates every other key AND is rendered on the page: a user must not be
     * told the data is ten minutes fresher than the cache it is being served
     * from.
     *
     * PRESENTED TO THE USER. Phase 2 traded live data for reconciliation, and
     * that trade is only honest if the page says when the figures are from.
     */
    protected function requisitionRefreshedAt(): ?string
    {
        return Cache::store(config('ledger.cache.store'))->remember(
            'finance-requisition:refreshed-at',
            config('ledger.requisition.version_seconds'),
            function () {
                try {
                    $value = DB::connection('FinanceAutomationSystem')
                        ->table('FinanceRequisitionRefresh')
                        ->where('Outcome', 'OK')
                        ->max('RefreshedAt');

                    return $value === null ? null : (string) $value;
                } catch (\Throwable $e) {
                    Log::warning('Finance requisition version probe failed; falling back to an unversioned cache key.', [
                        'exception' => $e->getMessage(),
                    ]);

                    return null;
                }
            }
        );
    }
}
