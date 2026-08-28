<script setup>
import RequisitionDetailView from '@/Components/RequisitionDetailView.vue'

/**
 * The requisition lines behind the ledger's Approved column.
 *
 * A thin wrapper: Inertia resolves components by file name, and this file's
 * name (spaces included) is what EncumberedDetailsController renders. All of
 * the behaviour lives in RequisitionDetailView so this page and the Routing one
 * cannot drift apart.
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
    fyNav: Object,
    snapshot: Object,
    unsummarisedYears: Array,
})
</script>

<template>
    <RequisitionDetailView
        route-name="encumbered-details.index"
        title="Encumbered Details"
        subtitle="The requisition lines behind your encumbered balance — the summary's Approved figure, line by line."
        money-label="Encumbered"
        empty-label="No encumbered requisition lines found"
        money-note="This is the summary&apos;s Approved column, net of receipts: a line already received is no longer a commitment. It counts toward reported expenditure but does not reduce your allocation balance."
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
        :fy-nav="fyNav"
        :snapshot="snapshot"
        :unsummarised-years="unsummarisedYears"
    />
</template>
