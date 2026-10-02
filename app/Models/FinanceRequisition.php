<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Builder;
use Illuminate\Database\Eloquent\Model;

/**
 * Read-only model over dbo.vw_FinanceRequisitionDetail — one row per
 * requisition LINE, which is the grain behind the ledger's account-grain
 * Approved and Routing columns. Same money, two grains; Phase 2's
 * reconciliation gate is what guarantees they agree.
 *
 * The view reads dbo.FinanceRequisitionSnapshot (rebuilt by STEP 2 of the
 * nightly Agent job) joined live to dbo.vw_WebAppUserAccess on the full
 * (Institution, Responsibility, Department) triple, so a permission change
 * takes effect on the next request with no refresh.
 *
 * THE VIEW IS NOT LIVE DATA. A requisition raised at 09:00 does not appear
 * until the next refresh — which is why every page built on this surfaces the
 * snapshot's RefreshedAt (see App\Concerns\VersionsRequisitionCache).
 *
 * NEVER point this at dbo.vw_FinanceRequisitionDetailUnscoped. "Unscoped"
 * there means the goods-and-services scope, not user access — but it is the
 * one surface whose totals cannot reconcile to the summary, which is precisely
 * the disagreement Phase 2 exists to prevent.
 */
class FinanceRequisition extends Model
{
    protected $connection = 'FinanceAutomationSystem';

    protected $table = 'vw_FinanceRequisitionDetail';

    protected $primaryKey = 'RequisitionNumber';

    protected $keyType = 'string';

    public $incrementing = false;

    public $timestamps = false;

    protected $guarded = ['*'];

    /**
     * Committed spend behind the summary's Approved column — approved
     * requisitions and raised purchase orders.
     */
    public const APPROVED_STATUSES = ['AP', 'PO'];

    /**
     * The pre-PO pipeline behind the summary's Routing column — in routing,
     * on hold, pending. These carry no shipments, so nothing is netted off.
     */
    public const ROUTING_STATUSES = ['RT', 'HD', 'PN'];

    protected function casts(): array
    {
        return [
            'OrderQuantity' => 'decimal:4',
            'QtyShipped' => 'decimal:4',
            'Quantity' => 'decimal:4',
            'UnitCost' => 'decimal:4',
            'ExtendedCost' => 'decimal:2',
        ];
    }

    protected static function booted(): void
    {
        static::creating(fn () => throw new \LogicException('FinanceRequisition is read-only.'));
        static::updating(fn () => throw new \LogicException('FinanceRequisition is read-only.'));
        static::deleting(fn () => throw new \LogicException('FinanceRequisition is read-only.'));
    }

    // =========================================================================
    // Scopes
    // =========================================================================

    public function scopeForUser(Builder $query, string $username): Builder
    {
        return $query->where('UserName', $username);
    }

    /**
     * NO LONGER USED BY THE TWO DETAIL PAGES. Since 2026-10-01 fiscal year is
     * an optional filter there, so RequisitionDetailController binds a year
     * LIST with whereIn() — one selected year, or every eligible year. Kept on
     * the shared model for any future single-year reader; do not reintroduce it
     * on those pages, where an unconditional whereIn is what enforces the
     * eligible-year bound (routingupdate.md §4).
     */
    public function scopeForYear(Builder $query, string $year): Builder
    {
        return $query->where('FinancialYear', $year);
    }

    /**
     * @param  array<int,string>  $statuses
     */
    public function scopeWithStatuses(Builder $query, array $statuses): Builder
    {
        return $query->whereIn('Status', $statuses);
    }
}
