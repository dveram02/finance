<script setup>
import { ref, computed, onMounted, onUnmounted } from 'vue'
import { Head, Link, router } from '@inertiajs/vue3'
import FiscalYearHero from '@/Components/FiscalYearHero.vue'
import LedgerLoadingOverlay from '@/Components/LedgerLoadingOverlay.vue'
import { useLedgerTable } from '@/composables/useLedgerTable'

const props = defineProps({
    rows:              Object,
    clusters:          Array,
    institutions:      Array,
    departments:       Array,
    descriptions:      Array,
    accounts:          Array,
    months:            Array,
    years:             Array,
    stats:             Object,
    totals:            Object,
    filters:           Object,
    activeFiscalYear:  [Number, String],
    currentFiscalYear: [Number, String],
    fyNav:             Object,
    isScaffold:        Boolean,
})

// ── Filter state (categorical only — FY is steered by the hero navigator) ───────
const filters = ref({
    cluster:     props.filters.cluster     ?? '',
    institution: props.filters.institution ?? '',
    department:  props.filters.department  ?? '',
    description: props.filters.description ?? '',
    account:     props.filters.account     ?? '',
    fy:          props.activeFiscalYear != null ? String(props.activeFiscalYear) : '',
})

// ── Navigation helpers ──────────────────────────────────────────────────────────
const applyFilters = () => {
    const params = Object.fromEntries(
        Object.entries(filters.value).filter(([, v]) => v !== '' && v !== null)
    )
    router.get(route('allocation-line-expenditure.index'), params, {
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

// Picking a specific account number implies its description, so the broader
// filter is cleared rather than left contradicting the narrower one.
const onAccountChange = () => {
    if (filters.value.account) filters.value.description = ''
    applyFilters()
}

const clearFilters = () => {
    filters.value = {
        cluster: '', institution: '', department: '',
        description: '', account: '', fy: filters.value.fy,
    }
    applyFilters()
}

// ── Cascades ────────────────────────────────────────────────────────────────────
const filteredInstitutions = computed(() => {
    if (!filters.value.cluster) return props.institutions
    return props.institutions.filter(i => i.ClusterName === filters.value.cluster)
})

// Narrow the account list to the chosen description, so the two account filters
// reinforce each other instead of offering contradictory options.
const filteredAccounts = computed(() => {
    if (!filters.value.description) return props.accounts
    return props.accounts.filter(a => a.AccountDescription === filters.value.description)
})

const activeFilterCount = computed(() =>
    ['cluster', 'institution', 'department', 'description', 'account']
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

// ── Loading state ───────────────────────────────────────────────────────────────
const loading = ref(false)
let stopOnStart = null
let stopOnFinish = null

onMounted(() => {
    stopOnStart = router.on('start', (event) => {
        const url = event.detail?.visit?.url
        if (!url || String(url.pathname ?? url).includes('allocation-line-expenditure')) {
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
const formatCurrency = (value) => {
    const n = Number(value ?? 0)
    const s = new Intl.NumberFormat('en-TT', { style: 'currency', currency: 'TTD' })
        .format(Math.abs(n))
    return n < 0 ? `(${s})` : s
}

// No currency symbol in the grid — repeated across twenty columns it is noise
// that costs width. The unit is declared once in the caption and on the KPIs.
const formatAmount = (value) => {
    const n = Number(value ?? 0)
    const s = new Intl.NumberFormat('en-TT', {
        minimumFractionDigits: 2, maximumFractionDigits: 2,
    }).format(Math.abs(n))
    return n < 0 ? `(${s})` : s
}

const isNegative = (value) => Number(value ?? 0) < 0
const isZero     = (value) => Number(value ?? 0) === 0

const clampedTitle = (text, maxChars) =>
    text && String(text).length > maxChars ? text : null

const IDENTITY_CLAMP = { institution: 44, department: 44, account: 52 }

// ── Allocation status ───────────────────────────────────────────────────────────
// The server classifies (under / exact / over) and supplies the amount; the
// wording is composed here, where the currency formatter already lives.
const STATUS_STYLES = {
    under: {
        icon: 'fa-circle-check',
        pill: 'bg-emerald-50 text-emerald-800 ring-emerald-600/20 dark:bg-emerald-400/10 dark:text-emerald-300 dark:ring-emerald-300/25',
    },
    exact: {
        icon: 'fa-equals',
        pill: 'bg-amber-50 text-amber-800 ring-amber-600/25 dark:bg-amber-400/10 dark:text-amber-300 dark:ring-amber-300/25',
    },
    over: {
        icon: 'fa-triangle-exclamation',
        pill: 'bg-red-50 text-red-800 ring-red-600/25 dark:bg-red-500/10 dark:text-red-300 dark:ring-red-400/25',
    },
}

const statusStyle = (key) => STATUS_STYLES[key] ?? STATUS_STYLES.under

const statusLabel = (row) => {
    if (row.StatusKey === 'over')  return `Exceeded by ${formatAmount(row.StatusAmount)}`
    if (row.StatusKey === 'exact') return 'Allocation fully spent'

    return `${formatAmount(row.StatusAmount)} remaining`
}

// Longer phrasing for the tooltip / screen readers, where there is room to be
// unambiguous about which figure the amount refers to.
const statusTitle = (row) => {
    if (row.StatusKey === 'over') {
        return `Expenditure has exceeded the allocation by ${formatAmount(row.StatusAmount)}.`
    }
    if (row.StatusKey === 'exact') {
        return 'Expenditure exactly equals the allocation; nothing remains.'
    }

    return `${formatAmount(row.StatusAmount)} of the allocation is still available.`
}
</script>

<template>
    <Head title="Allocation Line Expenditure" />

    <div class="space-y-6">

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

        <!-- ═══════════════════════ Scaffold / sample-data notice ═════════════════ -->
        <div v-if="isScaffold"
            class="p-3.5 rounded-xl border border-dashed border-amber-400/70 bg-amber-50/60 flex items-start gap-3 dark:border-amber-300/30 dark:bg-amber-400/5">
            <i class="fas fa-flask text-amber-600 mt-0.5 dark:text-amber-300"></i>
            <div>
                <p class="text-sm font-semibold text-amber-900 dark:text-amber-200">Sample data</p>
                <p class="text-xs text-amber-800/80 mt-0.5 dark:text-amber-200/70">
                    Every figure on this page is hardcoded for layout review. Live SQL Server data
                    is not connected yet.
                </p>
            </div>
        </div>

        <!-- ════════════════════════════ Page header ══════════════════════════════ -->
        <div class="text-center">
            <h1 class="font-display text-3xl font-bold text-tx-primary tracking-tight">Allocation Line Expenditure</h1>
            <p class="text-sm text-tx-subtle mt-1">
                Allocation against actual spend, line by line, across the fiscal year.
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
        <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">

            <div class="bg-surface rounded-xl border border-line p-5 relative overflow-hidden shadow-sm">
                <div class="absolute top-0 left-0 bottom-0 w-1 rounded-l-xl" style="background: #0ea5e9;"></div>
                <div class="pl-1">
                    <div class="flex items-start justify-between mb-3">
                        <div>
                            <p class="text-xs font-semibold text-tx-muted uppercase tracking-wider">Total Allocation</p>
                            <p class="text-[10px] text-tx-subtle mt-0.5">All filtered lines</p>
                        </div>
                        <div class="w-9 h-9 rounded-lg flex items-center justify-center flex-shrink-0" style="background: rgba(14,165,233,0.1);">
                            <i class="fas fa-vault text-sm" style="color: #0ea5e9;"></i>
                        </div>
                    </div>
                    <p class="font-display text-3xl font-bold leading-none tabular-nums text-tx-primary">
                        {{ formatCurrency(stats.totalAllocation) }}
                    </p>
                </div>
            </div>

            <div class="bg-surface rounded-xl border border-line p-5 relative overflow-hidden shadow-sm">
                <div class="absolute top-0 left-0 bottom-0 w-1 rounded-l-xl" style="background: #d97706;"></div>
                <div class="pl-1">
                    <div class="flex items-start justify-between mb-3">
                        <div>
                            <p class="text-xs font-semibold text-tx-muted uppercase tracking-wider">YTD Expenditure</p>
                            <p class="text-[10px] text-tx-subtle mt-0.5">Net of corrections</p>
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
                <div class="absolute top-0 left-0 bottom-0 w-1 rounded-l-xl" style="background: #059669;"></div>
                <div class="pl-1">
                    <div class="flex items-start justify-between mb-3">
                        <div>
                            <p class="text-xs font-semibold text-tx-muted uppercase tracking-wider">Balance of Allocation</p>
                            <p class="text-[10px] text-tx-subtle mt-0.5">Summed per line · excludes overspend</p>
                        </div>
                        <div class="w-9 h-9 rounded-lg flex items-center justify-center flex-shrink-0" style="background: rgba(5,150,105,0.1);">
                            <i class="fas fa-scale-balanced text-sm" style="color: #059669;"></i>
                        </div>
                    </div>
                    <p class="font-display text-3xl font-bold leading-none tabular-nums text-tx-primary">
                        {{ formatCurrency(stats.balance) }}
                    </p>
                </div>
            </div>

            <div class="bg-surface rounded-xl border border-line p-5 relative overflow-hidden shadow-sm">
                <div class="absolute top-0 left-0 bottom-0 w-1 rounded-l-xl"
                    :style="`background: ${stats.exceededCount ? '#dc2626' : '#6366f1'};`"></div>
                <div class="pl-1">
                    <div class="flex items-start justify-between mb-3">
                        <div>
                            <p class="text-xs font-semibold text-tx-muted uppercase tracking-wider">Lines Over Allocation</p>
                            <p class="text-[10px] text-tx-subtle mt-0.5">of {{ stats.accountCount }} filtered</p>
                        </div>
                        <div class="w-9 h-9 rounded-lg flex items-center justify-center flex-shrink-0"
                            :style="`background: ${stats.exceededCount ? 'rgba(220,38,38,0.1)' : 'rgba(99,102,241,0.1)'};`">
                            <i class="fas fa-triangle-exclamation text-sm"
                                :style="`color: ${stats.exceededCount ? '#dc2626' : '#4f46e5'};`"></i>
                        </div>
                    </div>
                    <p class="font-display text-3xl font-bold leading-none tabular-nums"
                        :class="stats.exceededCount ? 'text-red-600 dark:text-red-400' : 'text-tx-primary'">
                        {{ stats.exceededCount }}
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

            <div class="p-5 grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 xl:grid-cols-5 gap-3">

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
                    <label class="block text-xs font-medium text-tx-subtle mb-1">Department</label>
                    <select v-model="filters.department" @change="applyFilters"
                        class="w-full rounded-lg border border-line-input bg-surface px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-amber-500/60 focus:border-transparent transition">
                        <option value="">All Departments</option>
                        <option v-for="d in departments" :key="d" :value="d">{{ d }}</option>
                    </select>
                </div>

                <div>
                    <label class="block text-xs font-medium text-tx-subtle mb-1">Account Description</label>
                    <select v-model="filters.description" @change="applyFilters"
                        class="w-full rounded-lg border border-line-input bg-surface px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-amber-500/60 focus:border-transparent transition">
                        <option value="">All Descriptions</option>
                        <option v-for="d in descriptions" :key="d" :value="d">{{ d }}</option>
                    </select>
                </div>

                <div>
                    <label class="block text-xs font-medium text-tx-subtle mb-1">Account</label>
                    <select v-model="filters.account" @change="onAccountChange"
                        class="w-full rounded-lg border border-line-input bg-surface px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-amber-500/60 focus:border-transparent transition">
                        <option value="">All Accounts</option>
                        <option v-for="acc in filteredAccounts" :key="acc.AccountNumber" :value="acc.AccountNumber">
                            {{ acc.AccountDescription }} ({{ acc.AccountNumber }})
                        </option>
                    </select>
                </div>

            </div>
        </div>

        <!-- ════════════════════════════ Results table ════════════════════════════ -->
        <div class="bg-surface rounded-xl shadow-sm border border-line overflow-hidden relative">

            <div class="flex items-center justify-between gap-3 px-5 py-2.5 border-b border-line bg-surface-2">
                <p class="text-[11px] font-semibold uppercase tracking-[0.18em] text-tx-subtle">
                    Allocation vs expenditure · TTD
                </p>
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
                aria-label="Allocation line expenditure table, scrollable horizontally"
                @mouseenter="pointerInTable = true"
                @mouseleave="pointerInTable = false; clearHover()"
                @focusin="tableFocused = true"
                @focusout="tableFocused = false">
                <table class="ledger-table divide-y divide-line" @mouseover="onTableHover">
                    <colgroup>
                        <col class="w-inst" />
                        <col class="w-dept" />
                        <col class="w-desc" />
                        <col class="w-alloc" />
                        <col v-for="m in months" :key="m.key" class="w-month" />
                        <col class="w-enc" />
                        <col class="w-ytd" />
                        <col class="w-bal" />
                        <col class="w-status" />
                    </colgroup>

                    <thead>
                        <tr>
                            <th class="col-inst ledger-frz ledger-wrap px-3 py-3 text-left text-[11px] font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">
                                Institution
                            </th>
                            <th class="col-dept ledger-frz ledger-wrap px-3 py-3 text-left text-[11px] font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">
                                Department
                            </th>
                            <th class="col-desc ledger-frz ledger-edge-l ledger-wrap px-3 py-3 text-left text-[11px] font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">
                                Account Description
                            </th>

                            <th class="allocation-edge px-3 py-3 text-right text-[11px] font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">
                                Allocation
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

                            <th class="summary-edge px-3 py-3 text-right text-[11px] font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">
                                Encumbered
                            </th>
                            <th class="px-3 py-3 text-right text-[11px] font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">
                                YTD Expenditure
                            </th>
                            <th class="px-3 py-3 text-right text-[11px] font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">
                                Balance of Allocation
                            </th>
                            <th class="col-status ledger-frz ledger-edge-r px-3 py-3 text-left text-[11px] font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">
                                Status
                            </th>
                        </tr>
                    </thead>

                    <tbody class="divide-y divide-line">

                        <tr v-if="rows.data.length === 0">
                            <td :colspan="months.length + 8" class="px-4 py-16 text-center">
                                <div class="inline-grid place-items-center h-14 w-14 rounded-full bg-surface-3 mb-3">
                                    <i class="fas fa-folder-open text-xl text-tx-muted"></i>
                                </div>
                                <p class="text-sm font-medium text-tx-body">No allocation lines found</p>
                                <p class="text-xs text-tx-muted mt-1">
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
                            <td class="col-desc ledger-frz ledger-edge-l ledger-wrap px-3 py-3 text-sm align-top">
                                <div class="text-tx-body line-clamp-2" :title="clampedTitle(row.AccountDescription, IDENTITY_CLAMP.account)">
                                    {{ row.AccountDescription ?? '—' }}
                                </div>
                                <div class="acct-no text-[10px] text-tx-subtle font-mono mt-1" :title="row.AccountNumber">
                                    {{ row.AccountNumber ?? '—' }}
                                </div>
                            </td>

                            <td class="allocation-edge px-3 py-3 text-[13px] text-right whitespace-nowrap tabular-nums font-semibold text-tx-primary align-top">
                                {{ formatAmount(row.Allocation) }}
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
                                    'summary-edge px-3 py-3 text-[13px] text-right whitespace-nowrap tabular-nums align-top',
                                    isZero(row.Encumbered) ? 'text-tx-muted/40' : 'text-tx-body',
                                ]">
                                <template v-if="isZero(row.Encumbered)">–</template>
                                <template v-else>{{ formatAmount(row.Encumbered) }}</template>
                            </td>

                            <td :class="[
                                    'px-3 py-3 text-[13px] text-right whitespace-nowrap font-semibold tabular-nums align-top',
                                    isNegative(row.YTDTotal) ? 'text-red-600 dark:text-red-400' : 'text-tx-primary',
                                ]">
                                {{ formatAmount(row.YTDTotal) }}
                            </td>

                            <td :class="[
                                    'px-3 py-3 text-[13px] text-right whitespace-nowrap font-semibold tabular-nums align-top',
                                    isZero(row.AllocationBalance) ? 'text-tx-muted/50' : 'text-emerald-700 dark:text-emerald-400',
                                ]">
                                {{ formatAmount(row.AllocationBalance) }}
                            </td>

                            <td class="col-status ledger-frz ledger-edge-r px-3 py-3 align-top">
                                <span :title="statusTitle(row)"
                                    :class="[
                                        'inline-flex items-start gap-1.5 rounded-full px-2 py-1 text-[11px] font-semibold leading-tight ring-1',
                                        statusStyle(row.StatusKey).pill,
                                    ]">
                                    <i :class="['fas mt-px', statusStyle(row.StatusKey).icon]"></i>
                                    <span class="tabular-nums">{{ statusLabel(row) }}</span>
                                </span>
                            </td>
                        </tr>

                    </tbody>

                    <!-- Totals across the ENTIRE filtered set, not this page. -->
                    <tfoot v-if="rows.data.length">
                        <tr>
                            <td colspan="3" class="col-foot-label ledger-frz ledger-edge-l px-3 py-3 text-left align-middle">
                                <span class="text-[11px] font-semibold uppercase tracking-wider text-tx-subtle">Totals</span>
                                <span class="ml-2 text-[11px] text-tx-muted">
                                    all {{ stats.accountCount }} line{{ stats.accountCount === 1 ? '' : 's' }}
                                </span>
                            </td>

                            <td class="allocation-edge px-3 py-3 text-[13px] text-right whitespace-nowrap tabular-nums font-bold text-tx-primary">
                                {{ formatAmount(totals.allocation) }}
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

                            <td class="summary-edge px-3 py-3 text-[13px] text-right whitespace-nowrap tabular-nums font-semibold text-tx-primary">
                                {{ formatAmount(totals.encumbered) }}
                            </td>
                            <td class="px-3 py-3 text-[13px] text-right whitespace-nowrap tabular-nums font-bold text-tx-primary">
                                {{ formatAmount(totals.ytd) }}
                            </td>
                            <td class="px-3 py-3 text-[13px] text-right whitespace-nowrap tabular-nums font-bold text-emerald-700 dark:text-emerald-400">
                                {{ formatAmount(totals.balance) }}
                            </td>
                            <td class="col-status ledger-frz ledger-edge-r px-3 py-3">
                                <span v-if="totals.exceededCount"
                                    class="inline-flex items-center gap-1.5 rounded-full px-2 py-1 text-[11px] font-semibold ring-1 bg-red-50 text-red-800 ring-red-600/25 dark:bg-red-500/10 dark:text-red-300 dark:ring-red-400/25">
                                    <i class="fas fa-triangle-exclamation"></i>
                                    {{ totals.exceededCount }} over
                                </span>
                                <span v-else class="text-[11px] text-tx-muted">None over</span>
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
   app.css. Twenty columns, so the identity block matches Department Expenditure
   exactly — the two pages must feel like the same instrument — and only Status
   is frozen on the right. Freezing the whole summary block (Encumbered, YTD,
   Balance, Status) would pin ~32rem and leave almost no room for the months;
   Status is the column people scan, so it is the one worth the space. */

.w-inst   { width: 8rem; }
.w-dept   { width: 8rem; }
.w-desc   { width: 11rem; }
.w-alloc  { width: 7.5rem; }
.w-month  { width: 5.75rem; }
.w-enc    { width: 7.5rem; }
.w-ytd    { width: 8rem; }
.w-bal    { width: 8rem; }
.w-status { width: 11rem; }

@media (min-width: 1024px) {
    .col-inst { left: 0; }
    .col-dept { left: 8rem; }
    .col-desc { left: 16rem; }

    /* Spans the three identity columns, so it freezes as one cell at left: 0. */
    .col-foot-label { left: 0; }
}

@media (min-width: 1280px) {
    .w-inst  { width: 9.5rem; }
    .w-dept  { width: 9.5rem; }
    .w-desc  { width: 12rem; }
    .w-month { width: 6rem; }

    .col-dept { left: 9.5rem; }
    .col-desc { left: 19rem; }
}

@media (min-width: 1536px) {
    .w-inst  { width: 11rem; }
    .w-dept  { width: 11rem; }
    .w-desc  { width: 13rem; }

    .col-dept { left: 11rem; }
    .col-desc { left: 22rem; }
}

@media (min-width: 1920px) {
    .w-month { width: 7rem; }
}

/* Rules marking where the month block starts and ends, so Allocation reads as a
   reference figure and the summary columns as conclusions — rather than the
   twelve months bleeding into both. */
.allocation-edge { border-right: 2px solid rgba(251, 191, 36, 0.4); }
.summary-edge    { border-left: 2px solid rgba(251, 191, 36, 0.4); }
</style>
