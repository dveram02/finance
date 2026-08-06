<?php

namespace Tests\Feature\Concerns;

use App\Models\User;
use Illuminate\Support\Facades\DB;

/**
 * Acts as a user who actually has BUDGET rows — the dashboard's counterpart to
 * UsesLedgerData.
 *
 * The two are not interchangeable. UsesLedgerData resolves a username from
 * vw_FinanceLedger, but the dashboard's fiscal-year rail comes from
 * vw_BudgetAllocation, which filters Allocation <> 0 and so covers a strict
 * subset of those users. A ledger user with no allocation rows yields an empty
 * `years`, and every fiscal-year assertion below silently becomes a no-op —
 * PHPUnit reports that as *risky*, not failing, so it would pass unnoticed.
 *
 * Same skip-don't-fail contract as UsesLedgerData: there is no SQL Server in
 * CI, and a red suite on a machine with no database tells you nothing.
 */
trait UsesBudgetData
{
    private ?User $budgetUser = null;

    protected function budgetUser(): User
    {
        if ($this->budgetUser !== null) {
            return $this->budgetUser;
        }

        try {
            $username = DB::connection('FinanceAutomationSystem')
                ->table('vw_BudgetAllocation')
                ->whereNotNull('FinancialYear')
                ->distinct()
                ->value('UserName');
        } catch (\Throwable $e) {
            $this->markTestSkipped('SQL Server is unavailable: '.$e->getMessage());
        }

        if (! $username) {
            $this->markTestSkipped('No user has budget allocation rows. Run: php artisan ledger:refresh --all');
        }

        return $this->budgetUser = User::factory()->create(['username' => $username]);
    }
}
