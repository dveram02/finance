<?php

namespace Tests\Feature\Concerns;

use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

/**
 * Stands in for SWRHAExpenseControl.dbo.vw_WebAppUsers.
 *
 * The login flow is the one path in this application that reads the AUTH SQL
 * Server, and there is no SQL Server in CI — nor should a test suite depend on
 * a real directory of real staff passwords. So the connection is repointed at
 * an in-memory SQLite database carrying the same table name and the same
 * PascalCase columns, and SWRHAExpenseControlUser (which pins
 * $connection = 'SWRHAExpenseControl') reads it unchanged.
 *
 * This is deliberately NOT the markTestSkipped() approach used by
 * UsesLedgerData: the ledger is megabytes of derived financial data that
 * cannot be meaningfully faked, whereas a directory row is six columns. Login
 * is security-relevant enough that its tests must run everywhere, always.
 */
trait FakesExpenseControlDirectory
{
    protected function fakeExpenseControlDirectory(): void
    {
        config([
            'database.connections.SWRHAExpenseControl' => [
                'driver' => 'sqlite',
                'database' => ':memory:',
                'prefix' => '',
                'foreign_key_constraints' => false,
            ],
        ]);

        // Drop any previously resolved PDO so the new config takes effect. Do
        // this once per test: purging an :memory: connection discards the data.
        DB::purge('SWRHAExpenseControl');

        Schema::connection('SWRHAExpenseControl')->create('vw_WebAppUsers', function (Blueprint $table) {
            // EmployeeID is a STRING key in the real view (may be alphanumeric
            // or zero-padded) — mirrored here so a test can prove the padding
            // survives into users.employee_id.
            $table->string('EmployeeID')->primary();
            $table->string('EmployeeName')->nullable();   // LEFT JOIN — may be NULL
            $table->string('UserName');
            $table->string('UserPassword');               // plaintext in the source system
            $table->string('PositionID')->nullable();
            $table->boolean('IsActive')->default(true);
        });
    }

    /**
     * Insert a directory row and return it.
     *
     * @param  array<string,mixed>  $attributes
     * @return array<string,mixed>
     */
    protected function directoryUser(array $attributes = []): array
    {
        $row = array_merge([
            'EmployeeID' => '000123',
            'EmployeeName' => 'Felicia Figuera',
            'UserName' => 'FFIGUERA1',
            'UserPassword' => 'correct-horse-battery',
            'PositionID' => 'POS-1',
            'IsActive' => true,
        ], $attributes);

        DB::connection('SWRHAExpenseControl')->table('vw_WebAppUsers')->insert($row);

        return $row;
    }
}
