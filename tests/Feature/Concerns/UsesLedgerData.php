<?php

namespace Tests\Feature\Concerns;

use App\Models\User;
use Illuminate\Support\Facades\DB;

/**
 * Acts as a user who actually has finance ledger rows.
 *
 * The Monthly Expenditure and Variance pages used to serve hardcoded fixtures,
 * which made them testable anywhere. They now read
 * dbo.vw_FinanceLedger, so these tests need both a reachable SQL Server and a
 * user with rows in it. There is no SQL Server in CI, so every test that needs
 * data skips rather than fails when it cannot get any — a red suite on a
 * machine with no database tells you nothing.
 *
 * A local User is created with a username the ledger recognises; the ledger is
 * scoped by UserName, so acting as a factory user with a random name would
 * return an empty page and quietly turn every assertion into a no-op.
 */
trait UsesLedgerData
{
    private ?User $ledgerUser = null;

    protected function ledgerUser(): User
    {
        if ($this->ledgerUser !== null) {
            return $this->ledgerUser;
        }

        try {
            $username = DB::connection('FinanceAutomationSystem')
                ->table('vw_FinanceLedger')
                ->distinct()
                ->value('UserName');
        } catch (\Throwable $e) {
            $this->markTestSkipped('SQL Server is unavailable: '.$e->getMessage());
        }

        if (! $username) {
            $this->markTestSkipped('The finance ledger snapshot has no rows. Run: php artisan ledger:refresh --all');
        }

        return $this->ledgerUser = User::factory()->create(['username' => $username]);
    }
}
