<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Model;

class MonthlyExpenditure extends Model
{
    protected $connection   = 'FinanceAutomationSystem';
    protected $table        = 'MonthlyExpenditure';
    protected $primaryKey   = null;
    public    $incrementing = false;
    public    $timestamps   = false;
    protected $guarded      = ['*'];

    protected function casts(): array
    {
        return [
            'NetChange' => 'decimal:2',
        ];
    }

    protected static function booted(): void
    {
        static::creating(fn () => throw new \LogicException('MonthlyExpenditure is read-only.'));
        static::updating(fn () => throw new \LogicException('MonthlyExpenditure is read-only.'));
        static::deleting(fn () => throw new \LogicException('MonthlyExpenditure is read-only.'));
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
