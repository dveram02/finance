<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Model;

/**
 * Read-only model over dbo.vw_FinanceLedger — one row per account per fiscal
 * year, carrying the 12 fiscal months, the quarters, the YTD total, the
 * encumbrance figures and the allocation.
 *
 * The view reads from dbo.FinanceLedgerSnapshot (rebuilt on a schedule) joined
 * live to dbo.vw_WebAppUserAccess, so permission changes take effect at once
 * while the expensive ledger build stays off the request path.
 *
 * Scope: goods and services ONLY. The source restricts to reporting line 3's
 * 41 account codes; payroll is excluded by design — see CLAUDE.md.
 */
class FinanceLedger extends Model
{
    protected $connection = 'FinanceAutomationSystem';

    protected $table = 'vw_FinanceLedger';

    protected $primaryKey = 'AccountNumber';

    protected $keyType = 'string';

    public $incrementing = false;

    public $timestamps = false;

    protected $guarded = ['*'];

    /** The 12 fiscal month columns in period order — PeriodID 1 = Oct … 12 = Sep. */
    public const MONTHS = ['Oct', 'Nov', 'Dec', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep'];

    protected function casts(): array
    {
        return [
            'Oct' => 'decimal:2', 'Nov' => 'decimal:2', 'Dec' => 'decimal:2',
            'Jan' => 'decimal:2', 'Feb' => 'decimal:2', 'Mar' => 'decimal:2',
            'Apr' => 'decimal:2', 'May' => 'decimal:2', 'Jun' => 'decimal:2',
            'Jul' => 'decimal:2', 'Aug' => 'decimal:2', 'Sep' => 'decimal:2',
            'Q1' => 'decimal:2', 'Q2' => 'decimal:2', 'Q3' => 'decimal:2', 'Q4' => 'decimal:2',
            'YTDTotal' => 'decimal:2',
            'Approved' => 'decimal:2',
            'Routing' => 'decimal:2',
            'Allocation' => 'decimal:2',
            'ActualExpenditure' => 'decimal:2',
            'Excess' => 'decimal:2',
            'AllocationBalance' => 'decimal:2',
        ];
    }

    protected static function booted(): void
    {
        static::creating(fn () => throw new \LogicException('FinanceLedger is read-only.'));
        static::updating(fn () => throw new \LogicException('FinanceLedger is read-only.'));
        static::deleting(fn () => throw new \LogicException('FinanceLedger is read-only.'));
    }

    // =========================================================================
    // Scopes
    // =========================================================================

    public function scopeForUser(Builder $query, string $username): Builder
    {
        return $query->where('UserName', $username);
    }

    public function scopeForYear(Builder $query, string $year): Builder
    {
        return $query->where('FinancialYear', $year);
    }
}
