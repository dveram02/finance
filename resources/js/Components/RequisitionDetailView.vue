<script setup>
import { ref, computed, watch, onMounted, onUnmounted } from 'vue'
import { Head, Link, router } from '@inertiajs/vue3'
import FiscalYearHero from '@/Components/FiscalYearHero.vue'
import NoAccessNotice from '@/Components/NoAccessNotice.vue'
import ExportCsvButton from '@/Components/ExportCsvButton.vue'
import LedgerLoadingOverlay from '@/Components/LedgerLoadingOverlay.vue'
import SnapshotFreshness from '@/Components/SnapshotFreshness.vue'
import { useTableScroll } from '@/composables/useTableScroll'

/**
 * The whole of both requisition detail pages.
 *
 * Encumbered and Routing differ only in copy and the route they filter through,
 * so the page files under Pages/Expenditure are thin wrappers around this and
 * exist mainly because Inertia resolves components by file name. Keeping one
 * implementation is what stops the two drifting apart the way the fiscal-year
 * hero did before it was extracted.
 *
 * The table scrolls exactly like Monthly Expenditure — frozen header, frozen
 * totals row, frozen identity and money columns, one-column arrow-key scrolling
 * — because it shares the mechanics: the CSS in app.css (`ledger-table`) and
 * useTableScroll(), which was extracted from useLedgerTable() for this page.
 *
 * What it does NOT take from useLedgerTable() is the month-axis half: the
 * column crosshair and the per-row heat shading, both of which are scaled
 * against a row's twelve months. This is line-grain with no month axis, so heat
 * would be shading nothing. That is the seam the two composables were split
 * along, not a divergence in scroll behaviour.
 */
const props = defineProps({
    // ── Page identity (the only difference between Approved and Routing) ────
    routeName: { type: String, required: true },
    title: { type: String, required: true },
    subtitle: { type: String, required: true },
    // One sentence on what the money column means on THIS page. Approved is net
    // of receipts and counts toward the reported actual; Routing is a pre-PO
    // pipeline that is deducted from nothing. Conflating them is the misreading
    // this whole phase is meant to prevent.
    moneyNote: { type: String, required: true },
    moneyLabel: { type: String, default: 'Committed' },
    emptyLabel: { type: String, default: 'No requisitions found' },

    // ── Data ────────────────────────────────────────────────────────────────
    // False when the user maps to no department at all — a permanent state that
    // no retry or filter change fixes, so it must not read as "no results".
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
    snapshot: { type: Object, default: () => ({ refreshedAt: null, age: null }) },
    unsummarisedYears: { type: Array, default: () => [] },

    // ── The scope guard ─────────────────────────────────────────────────────
    // True when the selection covers more requisition lines than the server
    // will materialise, so NOTHING was counted. Every region that reports a
    // quantity is gated on this: a refusal is not a measurement of zero, and
    // rendering "TTD 0 · 0 requisitions · No requisition lines found" would
    // announce an oversized result as an empty one — the fake zero CLAUDE.md
    // forbids, in four places at once.
    scopeRefused: { type: Boolean, default: false },
    // Server-supplied, so the two cases (all-years vs a selected year, which
    // have different recoveries) cannot drift from the controller's constants.
    scopeRefusedMessage: { type: String, default: null },
})

// ── Filter state ────────────────────────────────────────────────────────────────
// Fiscal year is a FILTER on these two pages, not a banner — there is no hero,
// no year rail and no prev/next stepper here. Since 2026-10-01 it is also
// OPTIONAL, defaulting to All Fiscal Years (= every year this route's detail
// shares with the ledger), so activeFilterCount below COUNTS it and
// clearFilters resets it to All like any other filter.
//
// `years` comes back from SQL as strings and activeFiscalYear is a PHP int, so
// both sides of every v-model comparison are normalised with String().
const filters = ref({
    cluster: props.filters.cluster ?? '',
    institution: props.filters.institution ?? '',
    department: props.filters.department ?? '',
    account: props.filters.account ?? '',
    vendor: props.filters.vendor ?? '',
    status: props.filters.status ?? '',
    fy: props.activeFiscalYear != null ? String(props.activeFiscalYear) : '',
})

// ── Navigation ──────────────────────────────────────────────────────────────────
// The filters the screen has applied. Shared by the Inertia visit and the
// export link so a CSV can never describe a different set of rows than the
// table above it. `page` is absent because it was never a filter.
const queryParams = computed(() => Object.fromEntries(
    Object.entries(filters.value).filter(([, v]) => v !== '' && v !== null)
))

// Guarded like SideBar.vue does: a missing Ziggy degrades to a disabled
// button rather than blanking the page.
const exportUrl = computed(() =>
    typeof route === 'function' ? route(props.routeName.replace(/\.index$/, '.export'), queryParams.value) : null
)

const exportRowCount = computed(() => props.totals?.lines ?? 0)

const applyFilters = () => {
    router.get(route(props.routeName), queryParams.value, {
        preserveState: true,
        preserveScroll: true,
        replace: true,
    })
}

// Re-seed the local filter state from what the server actually honoured.
//
// `applyFilters` visits with preserveState, so this component instance — and its
// `filters` ref — survives the response. When the fiscal year changes, a
// categorical value that is no longer a valid option in the new year is dropped
// server-side by validFilter() and comes back null, but without this the local
// ref would keep the old value: the <select> would show an option it no longer
// has (rendering blank) while the table showed unfiltered rows. The server is
// the authority on which filters survived, so take its answer.
watch(() => props.filters, (applied) => {
    filters.value = {
        cluster: applied.cluster ?? '',
        institution: applied.institution ?? '',
        department: applied.department ?? '',
        account: applied.account ?? '',
        vendor: applied.vendor ?? '',
        status: applied.status ?? '',
        // '' is All Fiscal Years. The server reports null for All, so this
        // re-seeds the empty option rather than coercing to a concrete year —
        // do NOT "tidy" this into `?? currentFiscalYear`, which would make the
        // control required again and silently narrow the scope on every visit.
        fy: props.activeFiscalYear != null ? String(props.activeFiscalYear) : '',
    }
})

// ── Wide-table scrolling and the arrow keys ─────────────────────────────────
// Arrows scroll the table's columns while the pointer or focus is in it, and do
// NOTHING otherwise. These two pages deliberately have no page-level fiscal-year
// stepping: the year is a filter here, not a banner, so there is no rail for an
// arrow key to walk. `onPrevYear`/`onNextYear` are therefore left unset —
// useTableScroll guards with `if (step && step() !== false)`, so omitting them
// leaves the event alone outside the table instead of swallowing it.
//
// The four pages that kept the hero still step years with the arrows, via
// useFiscalYearNav or useLedgerTable. Do not fold the two behaviours together.
const {
    scroller, canScroll, pointerInTable, tableFocused, arrowsScrollTable,
} = useTableScroll({
    rowCount: () => props.rows?.data?.length ?? 0,
})

const filteredInstitutions = computed(() => {
    if (!filters.value.cluster) return props.institutions
    return props.institutions.filter(i => i.Cluster === filters.value.cluster)
})

const onClusterChange = () => {
    filters.value.institution = ''
    applyFilters()
}

const CATEGORICAL_FILTERS = ['cluster', 'institution', 'department', 'account', 'vendor', 'status']

// Separate from activeFilterCount because the empty-state copy needs to say
// "matching your filters" for a categorical narrowing but not for a chosen
// year — the year is already named in the sentence before it.
const categoricalFilterCount = computed(() =>
    CATEGORICAL_FILTERS.filter(k => filters.value[k] !== '' && filters.value[k] != null).length
)

// FY COUNTS now. It is optional and defaults to All, so a chosen year is an
// active filter exactly like a department. It was excluded while it was
// required, when the badge would have read 1 on a virgin page.
const activeFilterCount = computed(() =>
    categoricalFilterCount.value + (filters.value.fy ? 1 : 0)
)

// "Clear all" returns the year to All, like every other control. While the year
// was required it was deliberately preserved here.
const clearFilters = () => {
    filters.value = {
        cluster: '', institution: '', department: '',
        account: '', vendor: '', status: '', fy: '',
    }
    applyFilters()
}

// ── The selected scope ──────────────────────────────────────────────────────
// Read-only, and only the EMPTY-STATE copy uses it now ("Nothing in FY 2026" vs
// "Nothing in any fiscal year"). The banner states the scope in the header, and
// derives its own span and "Current" badge from activeFiscalYear — so the chip's
// periodSpan and isCurrentFiscalYear were removed with it rather than kept as a
// second derivation of the same two facts.
const hasFiscalYear = computed(() => props.activeFiscalYear != null && props.activeFiscalYear !== '')


// ── Loading state ───────────────────────────────────────────────────────────────
// Driven by Inertia's global visit events so it covers the selects, the fiscal
// year navigator and the pagination links alike. The path guard keeps the
// spinner from flashing when the user navigates away to another page.
const loading = ref(false)
let stopOnStart = null
let stopOnFinish = null

const pathFragment = computed(() => props.routeName.replace('.index', ''))

onMounted(() => {
    stopOnStart = router.on('start', (event) => {
        const url = event.detail?.visit?.url
        if (!url || String(url.pathname ?? url).includes(pathFragment.value)) {
            loading.value = true
        }
    })
    stopOnFinish = router.on('finish', () => {
        loading.value = false
    })
})

onUnmounted(() => {
    stopOnStart?.()
    stopOnFinish?.()
})

// ── Formatting ──────────────────────────────────────────────────────────────────
const formatCurrency = (value) =>
    new Intl.NumberFormat('en-TT', { style: 'currency', currency: 'TTD' }).format(value ?? 0)

const formatNumber = (value) =>
    Number(value ?? 0).toLocaleString('en-TT')

// Quantities are decimal(19,4) and are usually whole; trailing zeros on every
// row make the column unreadable, so they are trimmed rather than padded.
const formatQuantity = (value) => {
    const n = Number(value ?? 0)
    return Number.isInteger(n) ? n.toLocaleString('en-TT') : n.toLocaleString('en-TT', { maximumFractionDigits: 4 })
}

const formatDate = (value) => {
    if (!value) return '—'
    const date = new Date(value)
    if (Number.isNaN(date.getTime())) return value
    return date.toLocaleDateString('en-TT', { year: 'numeric', month: 'short', day: 'numeric' })
}
</script>

<template>
    <Head :title="title" />

    <div class="space-y-5">

        <NoAccessNotice v-if="!hasAccess" />

        <!-- ════════════════════════════ Flash messages ═══════════════════════════ -->
        <div v-if="$page.props.flash?.success"
            class="p-4 bg-green-50 border border-green-200 rounded-xl flex items-start gap-3 dark:bg-green-900/20 dark:border-green-800">
            <i class="fas fa-circle-check text-green-500 mt-0.5"></i>
            <p class="text-sm text-green-800 dark:text-green-200">{{ $page.props.flash.success }}</p>
        </div>
        <div v-if="$page.props.flash?.error"
            class="p-4 bg-red-50 border border-red-200 rounded-xl flex items-start gap-3 dark:bg-red-900/20 dark:border-red-800">
            <i class="fas fa-circle-exclamation text-red-500 mt-0.5"></i>
            <p class="text-sm text-red-800 dark:text-red-200">{{ $page.props.flash.error }}</p>
        </div>
        <div v-if="$page.props.flash?.warning"
            class="p-4 bg-amber-50 border border-amber-200 rounded-xl flex items-start gap-3 dark:bg-amber-900/20 dark:border-amber-800">
            <i class="fas fa-triangle-exclamation text-amber-500 mt-0.5"></i>
            <p class="text-sm text-amber-800 dark:text-amber-200">{{ $page.props.flash.warning }}</p>
        </div>

        <!-- ════════════════════════════ Page header ══════════════════════════════ -->
        <!-- Centred text, then the banner below it — the same order the four
             summary pages use, which is what "consistent with the other views"
             means structurally. The gold period chip that used to sit beside the
             <h1> is GONE: the banner states the scope now, and two statements of
             it invite the two to disagree. -->
        <div class="text-center">
            <h1 class="font-display text-3xl font-bold text-tx-primary tracking-tight">{{ title }}</h1>
            <p class="text-sm text-tx-subtle mt-1">{{ subtitle }}</p>
            <!-- Names the summary column this page drills into ("the summary's
                 Approved column, net of receipts…"). -->
            <p class="text-xs text-tx-subtle/80 mt-1">{{ moneyNote }}</p>
        </div>

        <!-- The same banner as the other four pages, DISPLAY-ONLY (2026-10-02).
             Three earlier attempts at this slot were reverted; what makes this
             one different is that the hero can now render the all-years state
             honestly instead of being forced to pick a year numeral:

               `all-years-label` fills the numeral slot with the words "All
               Years" when no fiscal year is selected, and the line beneath it
               becomes the span across the ELIGIBLE years — Oct of the earliest
               year's start to Sep of the latest year's end, derived in
               @/fiscalYear so it cannot disagree with the single-year span.

               `:controls="false"` strips the prev/next stepper and the year
               rail. The Filters card below owns the fiscal year — it counts in
               the filter badge and "Clear all" returns it to All — so a stepper
               here would be a second control for one value, and "previous" has
               no meaning from All.

             `fyNav` is deliberately NOT passed, there is no @select handler, and
             the page still calls useTableScroll with neither onPrevYear nor
             onNextYear, so arrow keys scroll columns and never step years.

             It reports NO QUANTITY, which is why it renders unchanged through a
             scope refusal, a source outage and a missing access mapping. Do not
             put a figure in it. -->
        <FiscalYearHero
            :active-fiscal-year="activeFiscalYear"
            :current-fiscal-year="currentFiscalYear"
            :years="years"
            all-years-label="All Years"
            :controls="false"
        />

        <!-- The quiet "as at … rebuilt nightly, not live" line was removed from
             this page on 2026-10-02; the ALARM was not. `faults-only` renders
             nothing while the snapshot is healthy or unreadable, and the amber
             strip when it is stale past 36h or the last run aborted. Keeping it
             matters because the production health-check task has never been
             registered, so a stopped Agent job is otherwise silent. -->
        <SnapshotFreshness
            faults-only
            :refreshed-at="snapshot?.refreshedAt"
            :age="snapshot?.age"
            :age-hours="snapshot?.ageHours"
            :state="snapshot?.state"
        />

        <!-- ════════════════════════════ KPI cards ════════════════════════════════ -->
        <!-- Everything that reports a QUANTITY is gated on a resolved scope. A
             refusal means "we did not count this", which is not "we counted
             zero" — the same reason the outage path flashes a warning instead of
             rendering TTD 0. -->
        <div v-if="!scopeRefused" class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">

            <!-- Total committed -->
            <div class="bg-surface rounded-xl border border-line p-5 relative overflow-hidden shadow-sm">
                <div class="absolute top-0 left-0 bottom-0 w-1 rounded-l-xl" style="background: #d97706;"></div>
                <div class="pl-1">
                    <div class="flex items-start justify-between mb-3">
                        <div>
                            <p class="text-xs font-semibold text-tx-muted uppercase tracking-wider">{{ moneyLabel }}</p>
                            <p class="text-[10px] text-tx-subtle mt-0.5">Across all filtered lines</p>
                        </div>
                        <div class="w-9 h-9 rounded-lg flex items-center justify-center flex-shrink-0" style="background: rgba(217,119,6,0.1);">
                            <i class="fas fa-file-invoice-dollar text-sm" style="color: #d97706;"></i>
                        </div>
                    </div>
                    <p class="text-[11px] font-semibold text-tx-muted mb-0.5">TTD</p>
                    <p class="font-display text-3xl font-bold text-tx-primary leading-none tabular-nums">
                        {{ formatNumber(Number(totals?.committed ?? 0).toFixed(2)) }}
                    </p>
                </div>
            </div>

            <!-- Requisitions -->
            <div class="bg-surface rounded-xl border border-line p-5 relative overflow-hidden shadow-sm">
                <div class="absolute top-0 left-0 bottom-0 w-1 rounded-l-xl" style="background: #6366f1;"></div>
                <div class="pl-1">
                    <div class="flex items-start justify-between mb-3">
                        <div>
                            <p class="text-xs font-semibold text-tx-muted uppercase tracking-wider">Requisitions</p>
                            <p class="text-[10px] text-tx-subtle mt-0.5">Distinct, not lines</p>
                        </div>
                        <div class="w-9 h-9 rounded-lg flex items-center justify-center flex-shrink-0" style="background: rgba(99,102,241,0.1);">
                            <i class="fas fa-clipboard-list text-sm" style="color: #4f46e5;"></i>
                        </div>
                    </div>
                    <p class="font-display text-3xl font-bold text-tx-primary leading-none tabular-nums">{{ formatNumber(totals?.requisitions) }}</p>
                </div>
            </div>

            <!-- Lines -->
            <div class="bg-surface rounded-xl border border-line p-5 relative overflow-hidden shadow-sm">
                <div class="absolute top-0 left-0 bottom-0 w-1 rounded-l-xl" style="background: #0ea5e9;"></div>
                <div class="pl-1">
                    <div class="flex items-start justify-between mb-3">
                        <div>
                            <p class="text-xs font-semibold text-tx-muted uppercase tracking-wider">Lines</p>
                            <p class="text-[10px] text-tx-subtle mt-0.5">
                                {{ formatNumber(totals?.vendors) }} vendors · {{ formatNumber(totals?.accounts) }} accounts
                            </p>
                        </div>
                        <div class="w-9 h-9 rounded-lg flex items-center justify-center flex-shrink-0" style="background: rgba(14,165,233,0.1);">
                            <i class="fas fa-list-ol text-sm" style="color: #0ea5e9;"></i>
                        </div>
                    </div>
                    <p class="font-display text-3xl font-bold text-tx-primary leading-none tabular-nums">{{ formatNumber(totals?.lines) }}</p>
                </div>
            </div>

            <!-- Largest line -->
            <div class="bg-surface rounded-xl border border-line p-5 relative overflow-hidden shadow-sm">
                <div class="absolute top-0 left-0 bottom-0 w-1 rounded-l-xl" style="background: #14b8a6;"></div>
                <div class="pl-1">
                    <div class="flex items-start justify-between mb-3">
                        <div>
                            <p class="text-xs font-semibold text-tx-muted uppercase tracking-wider">Largest Line</p>
                            <p class="text-[10px] text-tx-subtle mt-0.5 truncate max-w-[10rem]" :title="totals?.largest?.label">
                                {{ totals?.largest?.label || 'Single biggest line' }}
                            </p>
                        </div>
                        <div class="w-9 h-9 rounded-lg flex items-center justify-center flex-shrink-0" style="background: rgba(20,184,166,0.1);">
                            <i class="fas fa-arrow-up-wide-short text-sm" style="color: #14b8a6;"></i>
                        </div>
                    </div>
                    <p class="text-[11px] font-semibold text-tx-muted mb-0.5">TTD</p>
                    <p class="font-display text-3xl font-bold text-tx-primary leading-none tabular-nums">
                        {{ formatNumber(Number(totals?.largest?.amount ?? 0).toFixed(2)) }}
                    </p>
                </div>
            </div>

        </div>

        <!-- ════════════════════════════ Filters bar ══════════════════════════════ -->
        <div class="bg-surface rounded-xl shadow-sm border border-line overflow-hidden">
            <div class="flex items-center justify-between gap-3 px-5 py-3 border-b border-line bg-surface-2">
                <div class="flex items-center gap-2.5">
                    <i class="fas fa-sliders text-tx-subtle text-sm"></i>
                    <h2 class="text-sm font-semibold text-tx-primary">Filters</h2>
                    <span v-if="activeFilterCount"
                        class="inline-flex items-center justify-center min-w-[1.25rem] h-5 px-1.5 rounded-full bg-indigo-600 text-white text-[11px] font-bold">
                        {{ activeFilterCount }}
                    </span>
                </div>
                <div class="flex items-center gap-3">
                <!-- The export refuses this same scope server-side, so showing
                     it would be a dead control that blames the data ("no
                     matching rows") for a size problem. -->
                <ExportCsvButton
                    v-if="!scopeRefused"
                    :href="exportUrl"
                    :row-count="exportRowCount"
                    :busy="loading"
                    :has-access="hasAccess"
                />
                <button v-if="activeFilterCount" @click="clearFilters"
                    class="inline-flex items-center gap-1.5 text-xs font-medium text-tx-subtle hover:text-red-500 transition">
                    <i class="fas fa-xmark"></i>
                    Clear all
                </button>
                </div>
            </div>

            <!-- Seven controls, all ONE cell wide, in a 4-column grid: Fiscal
                 Year, Cluster, Institution, Department on the first row; Account,
                 Vendor, Status on the second, which therefore ends in one empty
                 cell. That trailing gap is accepted deliberately (asked for
                 2026-10-02) — Account used to span two cells to fill the row and
                 to give its long "DESCRIPTION (4-80400-H01-107-1157-00-000)"
                 options room, but a filter that is visibly twice the width of
                 every other one reads as more important than it is. Equal
                 widths, one orphan cell. -->
            <div class="p-5 grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-3">

                <!-- Fiscal year. OPTIONAL, defaulting to All — and "All" is this
                     ROUTE's eligible set (the years its detail shares with the
                     ledger: 11 for Encumbered, 3 for Routing on today's mapped
                     user), enforced in the query, never every year the snapshot
                     holds. Changing it re-visits immediately; any categorical
                     filter that is not an option in the new scope is dropped
                     server-side and re-seeded by the watch above.
                     `years` arrives newest-first, so the most-wanted year is at
                     the top. It stays ENABLED even in a refusal — it is the
                     only recovery from an oversized scope. -->
                <div>
                    <label class="block text-xs font-medium text-tx-subtle mb-1">Fiscal Year</label>
                    <select v-model="filters.fy" @change="applyFilters"
                        class="w-full rounded-lg border border-line-input bg-surface px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-amber-500/60 focus:border-transparent transition">
                        <option value="">All Fiscal Years</option>
                        <option v-for="year in years" :key="year" :value="String(year)">FY {{ year }}</option>
                    </select>
                    <!-- Fiscal years the detail holds but the summary does not.
                         Named rather than silently dropped: the rows exist, they
                         simply cannot be tied back to an allocation, so drilling
                         into them would show detail that reconciles against
                         nothing. Sits here because it explains this control. -->
                    <p v-if="unsummarisedYears?.length" class="mt-1.5 text-xs text-tx-subtle">
                        <i class="fas fa-circle-info text-[10px] mr-1" aria-hidden="true"></i>
                        FY {{ unsummarisedYears.join(', ') }}
                        <template v-if="unsummarisedYears.length === 1">has</template><template v-else>have</template>
                        requisition detail but no budget ledger, so
                        <template v-if="unsummarisedYears.length === 1">it is</template><template v-else>they are</template>
                        not offered here.
                    </p>
                </div>

                <div>
                    <label class="block text-xs font-medium text-tx-subtle mb-1">Cluster</label>
                    <select v-model="filters.cluster" @change="onClusterChange" :disabled="scopeRefused"
                        class="w-full rounded-lg border border-line-input bg-surface px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-amber-500/60 focus:border-transparent transition disabled:opacity-50 disabled:cursor-not-allowed">
                        <option value="">All Clusters</option>
                        <option v-for="cluster in clusters" :key="cluster" :value="cluster">{{ cluster }}</option>
                    </select>
                </div>

                <div>
                    <label class="block text-xs font-medium text-tx-subtle mb-1">Institution</label>
                    <select v-model="filters.institution" @change="applyFilters" :disabled="scopeRefused"
                        class="w-full rounded-lg border border-line-input bg-surface px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-amber-500/60 focus:border-transparent transition disabled:opacity-50 disabled:cursor-not-allowed">
                        <option value="">All Institutions</option>
                        <option v-for="inst in filteredInstitutions" :key="inst.Institution" :value="inst.Institution">
                            {{ inst.Institution }}
                        </option>
                    </select>
                </div>

                <div>
                    <label class="block text-xs font-medium text-tx-subtle mb-1">Department</label>
                    <select v-model="filters.department" @change="applyFilters" :disabled="scopeRefused"
                        class="w-full rounded-lg border border-line-input bg-surface px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-amber-500/60 focus:border-transparent transition disabled:opacity-50 disabled:cursor-not-allowed">
                        <option value="">All Departments</option>
                        <option v-for="dept in departments" :key="dept" :value="dept">{{ dept }}</option>
                    </select>
                </div>

                <div>
                    <label class="block text-xs font-medium text-tx-subtle mb-1">Account</label>
                    <select v-model="filters.account" @change="applyFilters" :disabled="scopeRefused"
                        class="w-full rounded-lg border border-line-input bg-surface px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-amber-500/60 focus:border-transparent transition disabled:opacity-50 disabled:cursor-not-allowed">
                        <option value="">All Accounts</option>
                        <option v-for="acc in accounts" :key="acc.AccountNumber" :value="acc.AccountNumber">
                            {{ acc.AccountDescription }} ({{ acc.AccountNumber }})
                        </option>
                    </select>
                </div>

                <div>
                    <label class="block text-xs font-medium text-tx-subtle mb-1">Vendor</label>
                    <select v-model="filters.vendor" @change="applyFilters" :disabled="scopeRefused"
                        class="w-full rounded-lg border border-line-input bg-surface px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-amber-500/60 focus:border-transparent transition disabled:opacity-50 disabled:cursor-not-allowed">
                        <option value="">All Vendors</option>
                        <option v-for="vendor in vendors" :key="vendor" :value="vendor">{{ vendor }}</option>
                    </select>
                </div>

                <div>
                    <label class="block text-xs font-medium text-tx-subtle mb-1">Status</label>
                    <select v-model="filters.status" @change="applyFilters" :disabled="scopeRefused"
                        class="w-full rounded-lg border border-line-input bg-surface px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-amber-500/60 focus:border-transparent transition disabled:opacity-50 disabled:cursor-not-allowed">
                        <option value="">All Statuses</option>
                        <option v-for="s in statuses" :key="s.Status" :value="s.Status">
                            {{ s.StatusName || s.Status }}
                        </option>
                    </select>
                </div>

                <!-- Why the six above are off. They are not merely optionless:
                     with no row set there are no options to offer, AND changing
                     one could not rescue an oversized scope anyway — they are
                     applied in memory after the bounded fetch, so they never
                     reach SQL. Choosing a fiscal year is the only recovery. -->
                <p v-if="scopeRefused" class="sm:col-span-2 lg:col-span-4 text-xs text-tx-subtle">
                    <i class="fas fa-circle-info text-[10px] mr-1" aria-hidden="true"></i>
                    Filters are unavailable until the selection is small enough to display.
                    Choose a fiscal year first.
                </p>

            </div>
        </div>

        <!-- ════════════════════════════ Results table ════════════════════════════ -->
        <!-- THE COLUMNS ARE THE REFERENCE QUERY'S FINAL PROJECTION, in its order.
             sql/Phase2RequisitionDetail_Approved.sql and _Routing.sql both end:

               RequisitionNumber, PONumber, StatusName, LineNbr, ItemDescription,
               AccountDescription, ReqDateCreated, UofM, ActBalance AS Quantity,
               UnitCost, ActCost AS ExtendedCost, Cluster, Institution,
               Department, ResponsibilityCentre, VendorName, FinYear

             and so does the finance team's own draft in sql/source/. Seventeen
             columns, this order. Do not add, drop or reorder without changing the
             reference queries too — these pages exist to show that result set.

             Mechanically the same wide table as Monthly Expenditure: frozen
             header, frozen totals row, frozen identity columns, and arrow keys
             that scroll one column at a time. Shared via `ledger-table` in
             app.css and useTableScroll. -->
        <!-- The refusal replaces the table ENTIRELY rather than sitting above an
             empty one. Left in place, the table's own empty state would read
             "No requisition lines found · Nothing in any fiscal year" — an
             oversized result announcing itself as an empty one — and the totals
             row and pagination would describe nothing. -->
        <div v-if="scopeRefused"
            class="rounded-xl border border-amber-300/70 bg-amber-50 p-5 text-sm text-amber-900
                   dark:border-amber-300/40 dark:bg-amber-400/10 dark:text-amber-100">
            <i class="fas fa-triangle-exclamation mr-2" aria-hidden="true"></i>
            {{ scopeRefusedMessage }}
        </div>

        <div v-else class="bg-surface rounded-xl shadow-sm border border-line overflow-hidden relative">

            <div class="flex items-center justify-between gap-3 px-5 py-2.5 border-b border-line bg-surface-2">
                <p class="text-[11px] font-semibold uppercase tracking-[0.18em] text-tx-subtle">
                    {{ moneyLabel }} requisition lines · TTD
                </p>
                <!-- Tells the user which thing the arrow keys are currently
                     pointed at, since they do double duty on this page. -->
                <p v-if="canScroll"
                    :class="[
                        'flex items-center gap-1.5 text-[11px] transition-colors',
                        arrowsScrollTable ? 'font-semibold text-amber-700 dark:text-amber-300' : 'text-tx-muted',
                    ]">
                    <i class="fas fa-arrows-left-right"></i>
                    <template v-if="arrowsScrollTable">← → scroll the columns</template>
                    <template v-else>Scroll, or hover and use ← →, for all 17 columns</template>
                </p>
            </div>

            <LedgerLoadingOverlay :show="loading" label="Loading requisitions" />

            <div ref="scroller"
                class="table-scroll overflow-x-auto"
                tabindex="0"
                role="region"
                aria-label="Requisition detail table, scrollable horizontally"
                @mouseenter="pointerInTable = true"
                @mouseleave="pointerInTable = false"
                @focusin="tableFocused = true"
                @focusout="tableFocused = false">
                <table class="ledger-table divide-y divide-line">
                    <!-- Column widths live here, not on the cells. With
                         table-layout: fixed the browser treats these as
                         authoritative, which is what keeps the frozen columns'
                         `left` offsets aligned with where the columns actually
                         start. Under the default auto layout, widths are merely
                         hints and the two drift apart. -->
                    <colgroup>
                        <col class="w-req" />
                        <col class="w-po" />
                        <col class="w-status" />
                        <col class="w-line" />
                        <col class="w-item" />
                        <col class="w-acct" />
                        <col class="w-date" />
                        <col class="w-uom" />
                        <col class="w-qty" />
                        <col class="w-cost" />
                        <col class="w-money" />
                        <col class="w-cluster" />
                        <col class="w-inst" />
                        <col class="w-dept" />
                        <col class="w-resp" />
                        <col class="w-vendor" />
                        <col class="w-fy" />
                    </colgroup>

                    <thead>
                        <tr>
                            <th class="col-req ledger-frz ledger-wrap px-3 py-3 text-left text-[11px] font-semibold text-tx-subtle uppercase tracking-wider">Requisition</th>
                            <th class="col-po ledger-frz ledger-edge-l ledger-wrap px-3 py-3 text-left text-[11px] font-semibold text-tx-subtle uppercase tracking-wider">PO</th>

                            <th data-scroll-col class="px-3 py-3 text-left text-[11px] font-semibold text-tx-subtle uppercase tracking-wider">Status</th>
                            <th data-scroll-col class="px-2.5 py-3 text-right text-[11px] font-semibold text-tx-subtle uppercase tracking-wider">Line</th>
                            <th data-scroll-col class="px-3 py-3 text-left text-[11px] font-semibold text-tx-subtle uppercase tracking-wider">Item Description</th>
                            <th data-scroll-col class="px-3 py-3 text-left text-[11px] font-semibold text-tx-subtle uppercase tracking-wider">Account Description</th>
                            <th data-scroll-col class="px-3 py-3 text-left text-[11px] font-semibold text-tx-subtle uppercase tracking-wider">Date Created</th>
                            <th data-scroll-col class="px-2.5 py-3 text-left text-[11px] font-semibold text-tx-subtle uppercase tracking-wider">UofM</th>
                            <th data-scroll-col class="px-2.5 py-3 text-right text-[11px] font-semibold text-tx-subtle uppercase tracking-wider" title="ActBalance — ordered less received. SIGNED, not floored at zero: an over-received line is negative. The quantity still on commitment.">Quantity</th>
                            <th data-scroll-col class="px-2.5 py-3 text-right text-[11px] font-semibold text-tx-subtle uppercase tracking-wider">Unit Cost</th>
                            <th data-scroll-col class="col-money px-3 py-3 text-right text-[11px] font-semibold text-tx-subtle uppercase tracking-wider" :title="moneyNote">Extended Cost</th>
                            <th data-scroll-col class="px-3 py-3 text-left text-[11px] font-semibold text-tx-subtle uppercase tracking-wider">Cluster</th>
                            <th data-scroll-col class="px-3 py-3 text-left text-[11px] font-semibold text-tx-subtle uppercase tracking-wider">Institution</th>
                            <th data-scroll-col class="px-3 py-3 text-left text-[11px] font-semibold text-tx-subtle uppercase tracking-wider">Department</th>
                            <th data-scroll-col class="px-3 py-3 text-left text-[11px] font-semibold text-tx-subtle uppercase tracking-wider">Responsibility Centre</th>
                            <th data-scroll-col class="px-3 py-3 text-left text-[11px] font-semibold text-tx-subtle uppercase tracking-wider">Vendor</th>
                            <th data-scroll-col class="px-2.5 py-3 text-right text-[11px] font-semibold text-tx-subtle uppercase tracking-wider">Fin Year</th>
                        </tr>
                    </thead>

                    <tbody class="divide-y divide-line">

                        <!-- Empty state. Three states, three messages: an outage
                             flashes a warning above, no mapping shows the notice
                             at the top of the page, and this is the third. -->
                        <tr v-if="rows.data.length === 0">
                            <td colspan="17" class="px-4 py-16 text-center">
                                <div class="inline-grid place-items-center h-14 w-14 rounded-full bg-surface-3 mb-3">
                                    <i class="fas fa-folder-open text-xl text-tx-muted"></i>
                                </div>
                                <p class="text-sm font-medium text-tx-body">
                                    {{ hasAccess ? emptyLabel : 'Department access is not configured' }}
                                </p>
                                <p v-if="hasAccess" class="text-xs text-tx-muted mt-1">
                                    Nothing
                                    <template v-if="hasFiscalYear">in <span class="font-semibold">FY {{ activeFiscalYear }}</span></template>
                                    <template v-else>in any fiscal year</template>
                                    <template v-if="categoricalFilterCount"> matching your filters</template>.
                                </p>
                            </td>
                        </tr>

                        <!-- Data rows -->
                        <tr v-for="(row, index) in rows.data" :key="index"
                            class="group hover:bg-amber-50/40 dark:hover:bg-amber-900/10 transition-colors">

                            <td class="col-req ledger-frz px-3 py-3 text-sm text-tx-primary font-semibold font-mono align-top">
                                <span class="acct-no block" :title="row.RequisitionNumber">{{ row.RequisitionNumber || '—' }}</span>
                            </td>
                            <!-- GP writes the literal 'MULTIPLE' when a line was
                                 fulfilled by more than one purchase order, so there
                                 is no single number to record. Source data, shown as
                                 the reference query shows it. -->
                            <td class="col-po ledger-frz ledger-edge-l px-3 py-3 text-sm text-tx-subtle font-mono align-top">
                                <span class="acct-no block" :title="row.PONumber">{{ row.PONumber || '—' }}</span>
                            </td>

                            <td class="px-3 py-3 text-sm align-top">
                                <span class="inline-flex items-center rounded-full bg-surface-3 px-2 py-0.5 text-[11px] font-semibold text-tx-body"
                                    :title="row.Status">
                                    {{ row.StatusName || row.Status || '—' }}
                                </span>
                            </td>
                            <td class="px-2.5 py-3 text-sm text-tx-subtle text-right tabular-nums align-top">{{ row.LineNbr ?? '—' }}</td>
                            <td class="ledger-wrap px-3 py-3 text-sm text-tx-body align-top">
                                <span class="line-clamp-2" :title="row.ItemDescription">{{ row.ItemDescription || row.ItemID || '—' }}</span>
                            </td>
                            <td class="ledger-wrap px-3 py-3 text-sm text-tx-body align-top">
                                <span class="line-clamp-2" :title="row.AccountDescription">{{ row.AccountDescription || '—' }}</span>
                            </td>
                            <td class="px-3 py-3 text-sm text-tx-body align-top whitespace-nowrap">{{ formatDate(row.ReqDateCreated) }}</td>
                            <td class="px-2.5 py-3 text-sm text-tx-subtle align-top">{{ row.UofM || '—' }}</td>
                            <!-- Ordered and received are not columns in the reference
                                 projection, so they live in the title: the quantity
                                 shown is what is LEFT on commitment, and a reader
                                 comparing it to a purchase order needs to know why
                                 the two differ. -->
                            <td class="px-2.5 py-3 text-sm text-right tabular-nums font-medium align-top"
                                :class="row.PartiallyReceived ? 'text-teal-700 dark:text-teal-300' : 'text-tx-body'"
                                :title="`Ordered ${formatQuantity(row.OrderQuantity)} · received ${formatQuantity(row.QtyShipped)}`">
                                {{ formatQuantity(row.Quantity) }}
                            </td>
                            <td class="px-2.5 py-3 text-sm text-tx-body text-right tabular-nums align-top">{{ formatCurrency(row.UnitCost) }}</td>
                            <td class="col-money px-3 py-3 text-sm text-tx-primary text-right tabular-nums font-semibold align-top">
                                {{ formatCurrency(row.ExtendedCost) }}
                            </td>
                            <td class="ledger-wrap px-3 py-3 text-sm text-tx-body align-top">
                                <span class="line-clamp-2" :title="row.Cluster">{{ row.Cluster || '—' }}</span>
                            </td>
                            <td class="ledger-wrap px-3 py-3 text-sm text-tx-body align-top">
                                <span class="line-clamp-2" :title="row.Institution">{{ row.Institution || '—' }}</span>
                            </td>
                            <td class="ledger-wrap px-3 py-3 text-sm text-tx-body align-top">
                                <span class="line-clamp-2" :title="row.Department">{{ row.Department || '—' }}</span>
                            </td>
                            <td class="ledger-wrap px-3 py-3 text-sm text-tx-body align-top">
                                <span class="line-clamp-2" :title="row.ResponsibilityCentre">{{ row.ResponsibilityCentre || '—' }}</span>
                            </td>
                            <td class="ledger-wrap px-3 py-3 text-sm text-tx-body align-top">
                                <span class="line-clamp-2" :title="row.VendorName">{{ row.VendorName || '—' }}</span>
                            </td>
                            <td class="px-2.5 py-3 text-sm text-tx-subtle text-right tabular-nums align-top">{{ row.FinancialYear ?? '—' }}</td>
                        </tr>

                    </tbody>

                    <!-- Totals over the WHOLE filtered set, not the visible page. -->
                    <tfoot v-if="rows.total > 0">
                        <tr>
                            <td colspan="8" class="col-foot-label ledger-frz ledger-edge-l px-3 py-3 text-[11px] font-semibold text-tx-subtle uppercase tracking-wider">
                                Total · {{ formatNumber(totals?.lines) }} lines
                            </td>
                            <td class="px-2.5 py-3 text-sm text-tx-body text-right tabular-nums font-semibold">{{ formatQuantity(totals?.quantity) }}</td>
                            <!-- Unit cost is a rate, not an amount: summing it would
                                 produce a number with no meaning. -->
                            <td></td>
                            <td class="col-money px-3 py-3 text-sm text-tx-primary text-right tabular-nums font-bold">
                                {{ formatCurrency(totals?.committed) }}
                            </td>
                            <td colspan="6"></td>
                        </tr>
                    </tfoot>
                </table>
            </div>

            <!-- Pagination -->
            <div v-if="rows.total > 0" class="bg-surface-2 px-4 py-3 border-t border-line">
                <div class="flex flex-col sm:flex-row items-center justify-between gap-4">
                    <p class="text-sm text-tx-body">
                        Showing <span class="font-semibold text-tx-primary">{{ rows.from }}</span> to
                        <span class="font-semibold text-tx-primary">{{ rows.to }}</span> of
                        <span class="font-semibold text-tx-primary">{{ rows.total }}</span> lines
                    </p>
                    <nav v-if="rows.last_page > 1" class="flex items-center gap-1">
                        <template v-for="link in rows.links" :key="link.label">
                            <Link v-if="link.url" :href="link.url" preserve-scroll
                                :class="['px-3 py-1.5 text-sm rounded-md transition tabular-nums',
                                    link.active ? 'bg-gradient-to-b from-amber-400 to-amber-500 text-[#1a1205] font-semibold shadow-sm' : 'text-tx-body hover:bg-surface-3']">
                                <span v-html="link.label"></span>
                            </Link>
                            <span v-else class="px-3 py-1.5 text-sm rounded-md opacity-40 text-tx-body">
                                <span v-html="link.label"></span>
                            </span>
                        </template>
                    </nav>
                </div>
            </div>

        </div>

    </div>
</template>

<style scoped>
/* ── Column widths and frozen offsets ──────────────────────────────────
   Only this table's column layout lives here; the mechanics are shared in
   app.css with Monthly Expenditure and Variance. The
   frozen columns' `left` values are the running sum of the widths before them,
   so widths and offsets are declared together at every breakpoint — splitting
   them apart is what lets them drift and open gaps between frozen columns.

   Breakpoints are chosen against CONTENT width, not viewport: the layout has a
   fixed 18rem sidebar from md up, so a 1024px viewport is really ~700px of
   table. Freezing starts at lg (see app.css).

   ONLY Requisition and PO are frozen. Extended Cost is the eleventh of
   seventeen columns in the reference query's projection, with Cluster,
   Institution, Department, Responsibility Centre, Vendor and Fin Year after it,
   so it cannot also be pinned to the right edge the way Department
   Expenditure pins YTD. It keeps the gold rule instead, which is what makes it
   findable while scrolling. */

.w-req     { width: 9rem; }
.w-po      { width: 8rem; }
.w-status  { width: 7.5rem; }
.w-line    { width: 3.5rem; }
.w-item    { width: 15rem; }
.w-acct    { width: 13rem; }
.w-date    { width: 7rem; }
.w-uom     { width: 4.5rem; }
.w-qty     { width: 6rem; }
.w-cost    { width: 7.5rem; }
.w-money   { width: 8.5rem; }
.w-cluster { width: 9rem; }
.w-inst    { width: 11rem; }
.w-dept    { width: 10rem; }
.w-resp    { width: 11rem; }
.w-vendor  { width: 12rem; }
.w-fy      { width: 5rem; }

@media (min-width: 1024px) {
    .col-req { left: 0; }
    .col-po  { left: 9rem; }

    /* Spans Requisition through UofM, so it freezes as one cell at left: 0. */
    .col-foot-label { left: 0; }
}

@media (min-width: 1280px) {
    .w-req    { width: 10rem; }
    .w-item   { width: 17rem; }
    .w-acct   { width: 14rem; }
    .w-vendor { width: 13rem; }

    .col-po { left: 10rem; }
}

@media (min-width: 1536px) {
    .w-req   { width: 11rem; }
    .w-money { width: 9.5rem; }

    .col-po { left: 11rem; }
}

/* Large desktops: only the free-text columns grow. Widening them costs nothing
   structurally, whereas changing a frozen width means re-deriving its offset. */
@media (min-width: 1920px) {
    .w-item   { width: 20rem; }
    .w-vendor { width: 15rem; }
    .w-resp   { width: 13rem; }
}

/* Extended Cost is the figure the page exists to show; the gold rule marks it
   the way Monthly Expenditure marks YTD. */
.col-money { border-left: 2px solid rgba(251, 191, 36, 0.4); }
</style>
