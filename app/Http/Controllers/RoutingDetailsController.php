<?php

namespace App\Http\Controllers;

use App\Models\FinanceRequisition;

/**
 * Routing Details — the requisition lines behind the ledger's Routing
 * column, at line grain.
 *
 * Statuses RT, HD and PN: the pre-PO pipeline. These have no purchase order and
 * therefore no shipments, so nothing is netted off and QtyShipped is zero
 * throughout — measured 2026-08-25, whole-table Routing was identical before
 * and after the receipts change for exactly that reason.
 *
 * Routing is DISPLAYED AND DEDUCTED FROM NOTHING in the summary: it reduces
 * neither the allocation balance nor the reported actual. It is a pipeline
 * figure, not a commitment, and this page must not imply otherwise.
 */
class RoutingDetailsController extends RequisitionDetailController
{
    protected function statuses(): array
    {
        return FinanceRequisition::ROUTING_STATUSES;
    }

    protected function component(): string
    {
        return 'Expenditure/Routing Details';
    }

    protected function routeName(): string
    {
        return 'routing-details.index';
    }
}
