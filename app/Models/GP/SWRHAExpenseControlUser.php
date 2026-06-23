<?php

namespace App\Models\GP;

use Illuminate\Database\Eloquent\Model;

/**
 * Read-only model for SWRHAExpenseControl.dbo.vw_WebAppUsers.
 * Used exclusively by SWRHAUserProvider for credential validation
 * and EnsureUserIsActive for active-status reverification.
 * Never write to this model.
 *
 * Columns (PascalCase, mirrored from the view):
 *   - EmployeeID   (string key — may be alphanumeric / zero-padded)
 *   - EmployeeName (LEFT JOIN to ArrearsDatabase.0002AEmployees — may be NULL)
 *   - UserName
 *   - UserPassword
 *   - PositionID
 *   - IsActive
 */
class SWRHAExpenseControlUser extends Model
{
    protected $connection = 'SWRHAExpenseControl';

    protected $table = 'vw_WebAppUsers';

    protected $primaryKey = 'EmployeeID';

    // EmployeeID is a (non-incrementing) string key in SQL Server — not an int.
    protected $keyType = 'string';

    public $incrementing = false;

    public $timestamps = false;

    protected $guarded = ['*'];

    public static function boot(): void
    {
        parent::boot();

        static::creating(fn () => throw new \LogicException('SWRHAExpenseControlUser is read-only.'));
        static::updating(fn () => throw new \LogicException('SWRHAExpenseControlUser is read-only.'));
        static::deleting(fn () => throw new \LogicException('SWRHAExpenseControlUser is read-only.'));
    }
}
