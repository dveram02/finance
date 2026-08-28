<?php

namespace Tests\Feature\Concerns;

use App\Models\User;
use Illuminate\Support\Facades\DB;

/**
 * Acts as a user who actually has requisition detail rows.
 *
 * The sibling of UsesLedgerData, and separate from it on purpose: the two
 * snapshots are built by two STEPS of one Agent job, so one can be present and
 * populated while the other is not. A test that needs requisition rows must
 * skip on the requisition snapshot's absence, not the ledger's.
 *
 * There is no SQL Server in CI, so every test that needs data SKIPS rather than
 * fails when it cannot get any — a red suite on a machine with no database
 * tells you nothing.
 *
 * The username is read from the view, never invented: the detail is scoped by
 * UserName through vw_WebAppUserAccess, so acting as a factory user with a
 * random name returns an empty page and quietly turns every foreach assertion
 * into a no-op that PHPUnit reports as risky, not failing.
 */
trait UsesRequisitionData
{
    private ?User $requisitionUser = null;

    protected function requisitionUser(): User
    {
        if ($this->requisitionUser !== null) {
            return $this->requisitionUser;
        }

        try {
            $username = DB::connection('FinanceAutomationSystem')
                ->table('vw_FinanceRequisitionDetail')
                ->distinct()
                ->value('UserName');
        } catch (\Throwable $e) {
            $this->markTestSkipped('SQL Server or the Phase 2 requisition views are unavailable: '.$e->getMessage());
        }

        if (! $username) {
            $this->markTestSkipped('The requisition snapshot has no rows. Run: php artisan requisition:refresh');
        }

        return $this->requisitionUser = User::factory()->create(['username' => $username]);
    }

    /**
     * A fiscal year that has rows for this user on the given status set, or null.
     *
     * Assertions that need a particular data shape must guard their premise and
     * skip rather than assume it.
     *
     * @param  array<int,string>  $statuses
     */
    protected function requisitionFiscalYear(string $username, array $statuses): ?string
    {
        $year = DB::connection('FinanceAutomationSystem')
            ->table('vw_FinanceRequisitionDetail')
            ->where('UserName', $username)
            ->whereIn('Status', $statuses)
            ->orderByDesc('FinancialYear')
            ->value('FinancialYear');

        return $year === null ? null : (string) $year;
    }
}
