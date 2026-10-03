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
            // varchar holding the STRINGS 'TRUE'/'FALSE', exactly as production
            // does - not a boolean. That is the whole point: (bool) 'FALSE' is
            // true in PHP, so a fake storing 0/1 tests a representation the
            // directory never produces and cannot catch the bug that caused.
            // Callers may still pass PHP booleans; see directoryUser().
            $table->string('IsActive')->default('TRUE');
        });

        // The BASE TABLE behind the view. vw_WebAppUsers does not expose the
        // audit columns, so the self-service password change has to write here
        // instead — which means the fake has to carry it too, or the one write
        // in the whole application would have no offline coverage.
        //
        // Deliberately NO unique index on UserName: production has none, and
        // adding one here would make the ambiguity-guard test unwritable.
        Schema::connection('SWRHAExpenseControl')->create('0006AWebAppControls', function (Blueprint $table) {
            $table->increments('LineID');
            $table->string('EmployeeID')->nullable();
            $table->string('UserName');
            $table->string('UserPassword')->nullable();
            $table->string('PositionID')->nullable();
            $table->string('IsActive')->default('TRUE');
            $table->string('CreatedBy')->nullable();
            // date/time in SQL Server, strings here on purpose: SQLite gives
            // date/time columns NUMERIC affinity, so whether '2026-10-03' lands
            // as TEXT or 0 depends on numeral parsing. The fake's job is to let
            // the write run and be asserted on, not to reproduce SQL Server's
            // type system.
            $table->string('DateCreated')->nullable();
            $table->string('TimeCreated')->nullable();
            $table->string('LastEditedBy')->nullable();
            $table->string('DateEdited')->nullable();
            $table->string('TimeEdited')->nullable();
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
            'IsActive' => 'TRUE',
        ], $attributes);

        DB::connection('SWRHAExpenseControl')->table('vw_WebAppUsers')->insert($row);

        // Insert the matching base-table row as well. In production the view IS
        // derived from this table; a fixture where the two disagree is a
        // fiction that can only ever hide a bug.
        $lineId = $this->directoryControlRow([
            'EmployeeID' => $row['EmployeeID'],
            'UserName' => $row['UserName'],
            'UserPassword' => $row['UserPassword'],
            'PositionID' => $row['PositionID'],
            'IsActive' => $row['IsActive'],
            'CreatedBy' => 'TEST FIXTURE',
            'DateCreated' => '2026-01-01',
            'TimeCreated' => '09:00:00',
        ]);

        return $row + ['LineID' => $lineId];
    }

    /**
     * Insert a row into the BASE TABLE only, returning its LineID.
     *
     * Needed on its own for the ambiguity guard, which has to create a second
     * row sharing a UserName. Note that SQLite compares TEXT case-sensitively,
     * so the case-variant half of that hazard (production's collation is
     * Latin1_General_CI_AS) cannot be reproduced here and is covered by
     * reasoning rather than by the suite.
     *
     * @param  array<string,mixed>  $attributes
     */
    protected function directoryControlRow(array $attributes = []): int
    {
        return DB::connection('SWRHAExpenseControl')
            ->table('0006AWebAppControls')
            ->insertGetId(array_merge([
                'EmployeeID' => '000123',
                'UserName' => 'FFIGUERA1',
                'UserPassword' => 'correct-horse-battery',
                'PositionID' => 'POS-1',
                'IsActive' => 'TRUE',
            ], $attributes), 'LineID');
    }

    /**
     * Read a base-table row back, for assertions.
     *
     * @param  array<string,mixed>  $where
     */
    protected function directoryControlRowWhere(array $where): ?object
    {
        return DB::connection('SWRHAExpenseControl')
            ->table('0006AWebAppControls')
            ->where($where)
            ->first();
    }
}
