<script setup>
import RequisitionDetailView from '@/Components/RequisitionDetailView.vue'

/**
 * The requisition lines behind the ledger's Routing column.
 *
 * A thin wrapper, for the same reason as the Approved page: Inertia resolves
 * components by file name, and the behaviour is shared.
 */
defineProps({
    hasAccess: { type: Boolean, default: true },
    rows: Object,
    clusters: Array,
    institutions: Array,
    departments: Array,
    accounts: Array,
    vendors: Array,
    statuses: Array,
    years: Array,
    totals: Object,
    filters: Object,
    activeFiscalYear: [Number, String],
    currentFiscalYear: [Number, String],
    snapshot: Object,
    unsummarisedYears: Array,
    // The scope guard. Forwarded, not interpreted — RequisitionDetailView owns
    // every decision about what a refusal suppresses.
    scopeRefused: Boolean,
    scopeRefusedMessage: String,
})
</script>

<template>
    <RequisitionDetailView
        route-name="routing-details.index"
        title="Routing Details"
        subtitle="The pre-purchase-order pipeline behind your Routing figure, line by line."
        money-label="In Routing"
        empty-label="No routing requisition lines found"
        money-note="The summary&apos;s Routing column — requisitions in routing, on hold or pending. These have no purchase order yet, so nothing has been received against them — and they reduce neither your allocation balance nor your reported expenditure."
        :has-access="hasAccess"
        :rows="rows"
        :clusters="clusters"
        :institutions="institutions"
        :departments="departments"
        :accounts="accounts"
        :vendors="vendors"
        :statuses="statuses"
        :years="years"
        :totals="totals"
        :filters="filters"
        :active-fiscal-year="activeFiscalYear"
        :current-fiscal-year="currentFiscalYear"
        :snapshot="snapshot"
        :unsummarised-years="unsummarisedYears"
        :scope-refused="scopeRefused"
        :scope-refused-message="scopeRefusedMessage"
    />
</template>
