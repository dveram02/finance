<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Model;

class BudgetAllocation extends Model
{
    protected $connection   = 'FinanceAutomationSystem';
    protected $table        = 'vw_BudgetAllocation';
    protected $primaryKey   = 'AccountNumber';
    protected $keyType      = 'string';
    public    $incrementing = false;
    public    $timestamps   = false;
    protected $guarded      = ['*'];

    protected function casts(): array
    {
        return [
            'TotalAllocation' => 'decimal:2',
        ];
    }

    protected static function booted(): void
    {
        static::creating(fn () => throw new \LogicException('BudgetAllocation is read-only.'));
        static::updating(fn () => throw new \LogicException('BudgetAllocation is read-only.'));
        static::deleting(fn () => throw new \LogicException('BudgetAllocation is read-only.'));
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
