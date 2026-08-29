<script setup>
import { ref, computed, onMounted, onUnmounted } from 'vue'
import { Head, Link, router } from '@inertiajs/vue3'
import FiscalYearHero from '@/Components/FiscalYearHero.vue'
import LedgerLoadingOverlay from '@/Components/LedgerLoadingOverlay.vue'
import { useLedgerTable } from '@/composables/useLedgerTable'
import NoAccessNotice from '@/Components/NoAccessNotice.vue'

const props = defineProps({
    // False when the user maps to no department at all — a permanent state that
    // no retry or filter change fixes, so it must not read as "no results".
    hasAccess: { type: Boolean, default: true },
    rows:              Object,
    clusters:          Array,
    institutions:      Array,
    responsibilities:  Array,
    departments:       Array,
    months:            Array,
    years:             Array,
    stats:             Object,
    totals:            Object,
    filters:           Object,
    activeFiscalYear:  [Number, String],
    currentFiscalYear: [Number, String],
    fyNav:             Object,
})

// ── Filter state (categorical only — FY is steered by the hero navigator) ───────
const filters = ref({
    cluster:        props.filters.cluster        ?? '',
    institution:    props.filters.institution    ?? '',
    responsibility: props.filters.responsibility ?? '',
    department:     props.filters.department     ?? '',
    fy:             props.activeFiscalYear != null ? String(props.activeFiscalYear) : '',
})

// ── Navigation helpers ──────────────────────────────────────────────────────────
const applyFilters = () => {
    const params = Object.fromEntries(
        Object.entries(filters.value).filter(([, v]) => v !== '' && v !== null)
    )
    router.get(route('monthly-expenditure.index'), params, {
        preserveState:  true,
        preserveScroll: true,
        replace:        true,
    })
}

const goToFy = (fy) => {
    filters.value.fy = String(fy)
    applyFilters()
}

const onClusterChange = () => {
    filters.value.institution = ''
    applyFilters()
}

const clearFilters = () => {
    filters.value = {
        cluster: '', institution: '', responsibility: '',
        department: '', fy: filters.value.fy,
    }
    applyFilters()
}

// ── Institution cascade ─────────────────────────────────────────────────────────
const filteredInstitutions = computed(() => {
    if (!filters.value.cluster) return props.institutions
    return props.institutions.filter(i => i.ClusterName === filters.value.cluster)
})

// FY is always set, so it is excluded from the "refine" affordances.
const activeFilterCount = computed(() =>
    ['cluster', 'institution', 'responsibility', 'department']
        .filter(k => filters.value[k] !== '' && filters.value[k] != null).length
)

// ── Shared ledger-table behaviour ───────────────────────────────────────────────
const {
    scroller, canScroll, hoveredMonth, onTableHover, clearHover,
    heatStyle, pointerInTable, tableFocused, arrowsScrollTable,
} = useLedgerTable({
    months: () => props.months ?? [],
    rows: () => props.rows?.data ?? [],
    onPrevYear: () => (props.fyNav?.prev != null ? goToFy(props.fyNav.prev) : false),
    onNextYear: () => (props.fyNav?.next != null ? goToFy(props.fyNav.next) : false),
})

// ── Loading state (shown while a filter / FY / page reload is in flight) ─────────
const loading = ref(false)
let stopOnStart = null
let stopOnFinish = null

onMounted(() => {
    stopOnStart = router.on('start', (event) => {
        const url = event.detail?.visit?.url
        if (!url || String(url.pathname ?? url).includes('monthly-expenditure')) {
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
// Accounting style: negatives in parentheses, e.g. ($1,234.56). Net figures are
// netted of correcting entries, so a value can legitimately be negative.
const formatCurrency = (value) => {
    const n = Number(value ?? 0)
    const s = new Intl.NumberFormat('en-TT', { style: 'currency', currency: 'TTD' })
        .format(Math.abs(n))
    return n < 0 ? `(${s})` : s
}

// Month cells carry no currency symbol — twelve repeated "TTD$" glyphs is noise
// that costs width and adds nothing. The symbol stays on the KPIs, and the
// column group is labelled TTD in the header.
const formatAmount = (value) => {
    const n = Number(value ?? 0)
    const s = new Intl.NumberFormat('en-TT', {
        minimumFractionDigits: 2, maximumFractionDigits: 2,
    }).format(Math.abs(n))
    return n < 0 ? `(${s})` : s
}

const isNegative = (value) => Number(value ?? 0) < 0
const isZero     = (value) => Number(value ?? 0) === 0

// Native `title` tooltips are only useful when text is actually cut off. Setting
// one unconditionally makes the browser echo back a label the user can already
// read in full, which just looks like stray text on hover. Returning null omits
// the attribute entirely. Thresholds are each column's approximate two-line
// capacity at its fixed width.
const clampedTitle = (text, maxChars) =>
    text && String(text).length > maxChars ? text : null

const IDENTITY_CLAMP = { institution: 44, department: 44, account: 52 }
</script>

<template>
    <Head title="Monthly Expenditure" />

    <div class="space-y-6">

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
        <div class="text-center">
            <h1 class="font-display text-3xl font-bold text-tx-primary tracking-tight">Monthly Expenditure</h1>
            <p class="text-sm text-tx-subtle mt-1">
                Expenditure by account, month by month across the fiscal year.
            </p>
        </div>

        <FiscalYearHero
            :active-fiscal-year="activeFiscalYear"
            :current-fiscal-year="currentFiscalYear"
            :years="years"
            :fy-nav="fyNav"
            @select="goToFy"
        />

        <!-- ════════════════════════════ KPI cards ════════════════════════════════ -->
        <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-4">

            <div class="bg-surface rounded-xl border border-line p-5 relative overflow-hidden shadow-sm">
                <div class="absolute top-0 left-0 bottom-0 w-1 rounded-l-xl" style="background: #d97706;"></div>
                <div class="pl-1">
                    <div class="flex items-start justify-between mb-3">
                        <div>
                            <p class="text-xs font-semibold text-tx-muted uppercase tracking-wider">Total YTD Expenditure</p>
                            <p class="text-[10px] text-tx-subtle mt-0.5">Net of corrections · all filtered accounts</p>
                        </div>
                        <div class="w-9 h-9 rounded-lg flex items-center justify-center flex-shrink-0" style="background: rgba(217,119,6,0.1);">
                            <i class="fas fa-coins text-sm" style="color: #d97706;"></i>
                        </div>
                    </div>
                    <p class="font-display text-3xl font-bold leading-none tabular-nums"
                        :class="isNegative(stats.totalExpenditure) ? 'text-red-600 dark:text-red-400' : 'text-tx-primary'">
                        {{ formatCurrency(stats.totalExpenditure) }}
                    </p>
                </div>
            </div>

            <div class="bg-surface rounded-xl border border-line p-5 relative overflow-hidden shadow-sm">
                <div class="absolute top-0 left-0 bottom-0 w-1 rounded-l-xl" style="background: #0ea5e9;"></div>
                <div class="pl-1">
                    <div class="flex items-start justify-between mb-3">
                        <div>
                            <p class="text-xs font-semibold text-tx-muted uppercase tracking-wider">Highest Spend Month</p>
                            <p class="text-[10px] text-tx-subtle mt-0.5">{{ stats.highestMonth?.label || 'No month' }}</p>
                        </div>
                        <div class="w-9 h-9 rounded-lg flex items-center justify-center flex-shrink-0" style="background: rgba(14,165,233,0.1);">
                            <i class="fas fa-calendar-day text-sm" style="color: #0ea5e9;"></i>
                        </div>
                    </div>
                    <p class="font-display text-3xl font-bold leading-none tabular-nums"
                        :class="isNegative(stats.highestMonth?.amount) ? 'text-red-600 dark:text-red-400' : 'text-tx-primary'">
                        {{ formatCurrency(stats.highestMonth?.amount) }}
                    </p>
                </div>
            </div>

            <div class="bg-surface rounded-xl border border-line p-5 relative overflow-hidden shadow-sm">
                <div class="absolute top-0 left-0 bottom-0 w-1 rounded-l-xl" style="background: #6366f1;"></div>
                <div class="pl-1">
                    <div class="flex items-start justify-between mb-3">
                        <div>
                            <p class="text-xs font-semibold text-tx-muted uppercase tracking-wider">Accounts Reported</p>
                            <p class="text-[10px] text-tx-subtle mt-0.5">Lines in FY {{ activeFiscalYear }}</p>
                        </div>
                        <div class="w-9 h-9 rounded-lg flex items-center justify-center flex-shrink-0" style="background: rgba(99,102,241,0.1);">
                            <i class="fas fa-list-ol text-sm" style="color: #4f46e5;"></i>
                        </div>
                    </div>
                    <p class="font-display text-3xl font-bold leading-none tabular-nums text-tx-primary">
                        {{ stats.accountCount }}
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
                <button v-if="activeFilterCount" @click="clearFilters"
                    class="inline-flex items-center gap-1.5 text-xs font-medium text-tx-subtle hover:text-red-500 transition">
                    <i class="fas fa-xmark"></i>
                    Clear all
                </button>
            </div>

            <div class="p-5 grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-3">

                <!-- Department leads: this report is departmental, so it is the
                     filter users reach for first. -->
                <div>
                    <label class="block text-xs font-medium text-tx-subtle mb-1">Department</label>
                    <select v-model="filters.department" @change="applyFilters"
                        class="w-full rounded-lg border border-line-input bg-surface px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-amber-500/60 focus:border-transparent transition">
                        <option value="">All Departments</option>
                        <option v-for="d in departments" :key="d" :value="d">{{ d }}</option>
                    </select>
                </div>

                <div>
                    <label class="block text-xs font-medium text-tx-subtle mb-1">Cluster</label>
                    <select v-model="filters.cluster" @change="onClusterChange"
                        class="w-full rounded-lg border border-line-input bg-surface px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-amber-500/60 focus:border-transparent transition">
                        <option value="">All Clusters</option>
                        <option v-for="cluster in clusters" :key="cluster" :value="cluster">{{ cluster }}</option>
                    </select>
                </div>

                <div>
                    <label class="block text-xs font-medium text-tx-subtle mb-1">Institution</label>
                    <select v-model="filters.institution" @change="applyFilters"
                        class="w-full rounded-lg border border-line-input bg-surface px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-amber-500/60 focus:border-transparent transition">
                        <option value="">All Institutions</option>
                        <option v-for="inst in filteredInstitutions" :key="inst.InstitutionName" :value="inst.InstitutionName">
                            {{ inst.InstitutionName }}
                        </option>
                    </select>
                </div>

                <div>
                    <label class="block text-xs font-medium text-tx-subtle mb-1">Responsibility Centre</label>
                    <select v-model="filters.responsibility" @change="applyFilters"
                        class="w-full rounded-lg border border-line-input bg-surface px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-amber-500/60 focus:border-transparent transition">
                        <option value="">All Responsibility Centres</option>
                        <option v-for="r in responsibilities" :key="r" :value="r">{{ r }}</option>
                    </select>
                </div>

            </div>
        </div>

        <!-- ════════════════════════════ Results table ════════════════════════════ -->
        <div class="bg-surface rounded-xl shadow-sm border border-line overflow-hidden relative">

            <div class="flex items-center justify-between gap-3 px-5 py-2.5 border-b border-line bg-surface-2">
                <p class="text-[11px] font-semibold uppercase tracking-[0.18em] text-tx-subtle">
                    Monthly net expenditure · TTD
                </p>
                <!-- Tells the user which thing the arrow keys are currently
                     pointed at, since they do double duty on this page. -->
                <p v-if="canScroll"
                    :class="[
                        'flex items-center gap-1.5 text-[11px] transition-colors',
                        arrowsScrollTable ? 'font-semibold text-amber-700 dark:text-amber-300' : 'text-tx-muted',
                    ]">
                    <i class="fas fa-arrows-left-right"></i>
                    <template v-if="arrowsScrollTable">← → scroll the months</template>
                    <template v-else>Scroll, or hover and use ← →, for all 12 months</template>
                </p>
            </div>

            <LedgerLoadingOverlay :show="loading" />

            <div ref="scroller"
                class="table-scroll overflow-x-auto"
                tabindex="0"
                role="region"
                aria-label="Monthly expenditure table, scrollable horizontally"
                @mouseenter="pointerInTable = true"
                @mouseleave="pointerInTable = false; clearHover()"
                @focusin="tableFocused = true"
                @focusout="tableFocused = false">
                <table class="ledger-table divide-y divide-line" @mouseover="onTableHover">
                    <!-- Column widths live here, not on the cells. With
                         table-layout: fixed the browser treats these as
                         authoritative, which is what keeps the frozen columns'
                         `left` offsets aligned with where the columns actually
                         start. Under the default auto layout, widths are merely
                         hints and the two drift apart. -->
                    <colgroup>
                        <col class="w-inst" />
                        <col class="w-dept" />
                        <col class="w-acct" />
                        <col v-for="m in months" :key="m.key" class="w-month" />
                        <col class="w-ytd" />
                    </colgroup>

                    <thead>
                        <tr>
                            <th class="col-inst ledger-frz ledger-wrap px-3 py-3 text-left text-[11px] font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">
                                Institution
                            </th>
                            <th class="col-dept ledger-frz ledger-wrap px-3 py-3 text-left text-[11px] font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">
                                Department
                            </th>
                            <th class="col-acct ledger-frz ledger-edge-l ledger-wrap px-3 py-3 text-left text-[11px] font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">
                                Account
                            </th>

                            <th v-for="(m, i) in months" :key="m.key"
                                :data-month-index="i"
                                :class="[
                                    'px-2.5 py-3 text-right text-[11px] font-semibold uppercase tracking-wider whitespace-nowrap',
                                    m.quarterStart ? 'quarter-edge' : '',
                                    hoveredMonth === i ? 'is-col-hover text-amber-700 dark:text-amber-300'
                                        : m.future ? 'text-tx-muted/50' : 'text-tx-subtle',
                                ]">
                                {{ m.label }}
                                <span class="block text-[9px] font-normal tabular-nums opacity-70">'{{ m.year }}</span>
                            </th>

                            <th class="col-ytd ledger-frz ledger-edge-r px-3 py-3 text-right text-[11px] font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">
                                YTD
                            </th>
                        </tr>
                    </thead>

                    <tbody class="divide-y divide-line">

                        <tr v-if="rows.data.length === 0">
                            <td :colspan="months.length + 4" class="px-4 py-16 text-center">
                                <div class="inline-grid place-items-center h-14 w-14 rounded-full bg-surface-3 mb-3">
                                    <i class="fas fa-folder-open text-xl text-tx-muted"></i>
                                </div>
                                <p class="text-sm font-medium text-tx-body">
                                    {{ hasAccess ? 'No expenditure found' : 'Department access is not configured' }}
                                </p>
                                <p v-if="hasAccess" class="text-xs text-tx-muted mt-1">
                                    Nothing in <span class="font-semibold">FY {{ activeFiscalYear }}</span>
                                    <template v-if="activeFilterCount"> matching your filters</template>.
                                </p>
                            </td>
                        </tr>

                        <tr v-for="(row, rowIndex) in rows.data" :key="rowIndex"
                            class="group hover:bg-amber-50/40 dark:hover:bg-amber-900/10 transition-colors">

                            <td class="col-inst ledger-frz ledger-wrap px-3 py-3 text-sm text-tx-body align-top">
                                <span class="line-clamp-2" :title="clampedTitle(row.InstitutionName, IDENTITY_CLAMP.institution)">
                                    {{ row.InstitutionName ?? '—' }}
                                </span>
                            </td>
                            <td class="col-dept ledger-frz ledger-wrap px-3 py-3 text-sm text-tx-body align-top">
                                <span class="line-clamp-2" :title="clampedTitle(row.DepartmentName, IDENTITY_CLAMP.department)">
                                    {{ row.DepartmentName ?? '—' }}
                                </span>
                            </td>
                            <td class="col-acct ledger-frz ledger-edge-l ledger-wrap px-3 py-3 text-sm align-top">
                                <div class="text-tx-body line-clamp-2" :title="clampedTitle(row.AccountDescription, IDENTITY_CLAMP.account)">
                                    {{ row.AccountDescription ?? '—' }}
                                </div>
                                <!-- Fixed-format 27-char identifier, held to one line:
                                     wrapping it added a whole line to every row. -->
                                <div class="acct-no text-[10px] text-tx-subtle font-mono mt-1" :title="row.AccountNumber">
                                    {{ row.AccountNumber ?? '—' }}
                                </div>
                            </td>

                            <td v-for="(m, i) in months" :key="m.key"
                                :data-month-index="i"
                                :style="heatStyle(row, m.key, rowIndex)"
                                :class="[
                                    'px-2.5 py-3 text-[13px] text-right whitespace-nowrap tabular-nums align-top',
                                    m.quarterStart ? 'quarter-edge' : '',
                                    hoveredMonth === i ? 'is-col-hover' : '',
                                    isZero(row[m.key])   ? 'text-tx-muted/40'
                                        : isNegative(row[m.key]) ? 'text-red-600 dark:text-red-400'
                                        : 'text-tx-body',
                                ]">
                                <template v-if="isZero(row[m.key])">–</template>
                                <template v-else>{{ formatAmount(row[m.key]) }}</template>
                            </td>

                            <td :class="[
                                    'col-ytd ledger-frz ledger-edge-r px-3 py-3 text-sm text-right whitespace-nowrap font-semibold tabular-nums align-top',
                                    isNegative(row.YTDTotal) ? 'text-red-600 dark:text-red-400' : 'text-tx-primary',
                                ]">
                                <span class="border-b border-transparent group-hover:border-amber-400/60 transition-colors">
                                    {{ formatAmount(row.YTDTotal) }}
                                </span>
                            </td>
                        </tr>

                    </tbody>

                    <!-- Totals across the ENTIRE filtered set, not this page. Said
                         explicitly in the label, because a totals row sitting under
                         25 visible rows otherwise reads as the sum of those rows. -->
                    <tfoot v-if="rows.data.length">
                        <tr>
                            <td colspan="3" class="col-foot-label ledger-frz ledger-edge-l px-3 py-3 text-left align-middle">
                                <span class="text-[11px] font-semibold uppercase tracking-wider text-tx-subtle">Totals</span>
                                <span class="ml-2 text-[11px] text-tx-muted">
                                    all {{ stats.accountCount }} account{{ stats.accountCount === 1 ? '' : 's' }}
                                </span>
                            </td>

                            <td v-for="(m, i) in months" :key="m.key"
                                :data-month-index="i"
                                :class="[
                                    'px-2.5 py-3 text-[13px] text-right whitespace-nowrap tabular-nums font-semibold',
                                    m.quarterStart ? 'quarter-edge' : '',
                                    hoveredMonth === i ? 'is-col-hover' : '',
                                    isZero(totals.months[m.key]) ? 'text-tx-muted/40'
                                        : isNegative(totals.months[m.key]) ? 'text-red-600 dark:text-red-400'
                                        : 'text-tx-primary',
                                ]">
                                <template v-if="isZero(totals.months[m.key])">–</template>
                                <template v-else>{{ formatAmount(totals.months[m.key]) }}</template>
                            </td>

                            <td :class="[
                                    'col-ytd ledger-frz ledger-edge-r px-3 py-3 text-sm text-right whitespace-nowrap font-bold tabular-nums',
                                    isNegative(totals.ytd) ? 'text-red-600 dark:text-red-400' : 'text-tx-primary',
                                ]">
                                {{ formatAmount(totals.ytd) }}
                            </td>
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
                        <span class="font-semibold text-tx-primary">{{ rows.total }}</span> results
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
/* ── Column widths and frozen offsets ────────────────────────────────────────
   Only this page's column layout lives here; the table mechanics are shared in
   app.css. Each column's `left` is the running sum of the widths before it, so
   widths and offsets are declared together at every breakpoint — splitting them
   apart is what lets them drift and open gaps between frozen columns.

   Breakpoints are chosen against CONTENT width, not viewport: the layout has a
   fixed 18rem sidebar from md up, so a 1024px viewport is really ~700px of
   table. Freezing starts at lg (see app.css) with deliberately tight columns. */

.w-inst  { width: 8rem; }
.w-dept  { width: 8rem; }
.w-acct  { width: 11rem; }
.w-month { width: 5.75rem; }
.w-ytd   { width: 7rem; }

@media (min-width: 1024px) {
    .col-inst { left: 0; }
    .col-dept { left: 8rem; }
    .col-acct { left: 16rem; }

    /* Spans the three identity columns, so it freezes as one cell at left: 0. */
    .col-foot-label { left: 0; }
}

@media (min-width: 1280px) {
    .w-inst  { width: 9.5rem; }
    .w-dept  { width: 9.5rem; }
    .w-acct  { width: 12rem; }
    .w-month { width: 6rem; }

    .col-dept { left: 9.5rem; }
    .col-acct { left: 19rem; }
}

@media (min-width: 1536px) {
    .w-inst  { width: 11rem; }
    .w-dept  { width: 11rem; }
    .w-acct  { width: 13rem; }

    .col-dept { left: 11rem; }
    .col-acct { left: 22rem; }
}

/* Large desktops: only the month columns grow. Widening them costs nothing
   structurally, whereas changing identity widths means re-deriving the offsets. */
@media (min-width: 1920px) {
    .w-month { width: 7rem; }
}

/* The YTD column stays visually separated from the months at every size. */
.col-ytd { border-left: 2px solid rgba(251, 191, 36, 0.4); }
</style>
