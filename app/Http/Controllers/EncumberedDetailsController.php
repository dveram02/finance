<?php

namespace App\Http\Controllers;

use App\Models\FinanceRequisition;

/**
 * Encumbered Details — the requisition lines behind the ledger's Approved
 * column, at line grain.
 *
 * Statuses AP and PO. These carry shipments, so ExtendedCost here is NET OF
 * RECEIPTS: a line that has been fully received contributes nothing, because
 * its cost has already landed in the GL as posted spend and counting it again
 * as an open commitment would double it.
 *
 * Approved counts toward the summary's reported ActualExpenditure but does NOT
 * reduce AllocationBalance — see App\Concerns\DerivesAllocationLines.
 */
class EncumberedDetailsController extends RequisitionDetailController
{
    protected function statuses(): array
    {
        return FinanceRequisition::APPROVED_STATUSES;
    }

    protected function component(): string
    {
        return 'Expenditure/Encumbered Details';
    }

    protected function routeName(): string
    {
        return 'encumbered-details.index';
    }
}
