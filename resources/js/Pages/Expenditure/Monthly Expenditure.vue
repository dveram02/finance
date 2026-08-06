<script setup>
import { ref, computed, onMounted, onUnmounted } from 'vue'
import { Head, Link, router } from '@inertiajs/vue3'
import NoAccessNotice from '@/Components/NoAccessNotice.vue'
import FiscalYearHero from '@/Components/FiscalYearHero.vue'
import LedgerLoadingOverlay from '@/Components/LedgerLoadingOverlay.vue'
import { useFiscalYearNav } from '@/composables/useFiscalYearNav'

const props = defineProps({
    // False when the user maps to no department at all — a permanent state that
    // no retry or filter change fixes, so it must not read as "no results".
    hasAccess: { type: Boolean, default: true },
    rows:              Object,
    clusters:          Array,
    institutions:      Array,
    responsibilities:  Array,
    accounts:          Array,
    months:            Array,
    mainGroups:        Array,
    years:             Array,
    stats:             Object,
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
    account:        props.filters.account        ?? '',
    // PeriodID is numeric but a <select> value is a string — keep it a string both
    // ways so the echoed-back filter re-selects the active month after a reload.
    period:         props.filters.period != null ? String(props.filters.period) : '',
    group:          props.filters.group          ?? '',
    fy:             props.activeFiscalYear != null ? String(props.activeFiscalYear) : '',
})

// ── Fiscal year ─────────────────────────────────────────────────────────────────
// FiscalYearHero already ignores a null or unchanged year, so no guards here.
const goToFy = (fy) => {
    filters.value.fy = String(fy)
    applyFilters()
}

useFiscalYearNav({ fyNav: () => props.fyNav, goToFy })

// ── Institution cascade ─────────────────────────────────────────────────────────
const filteredInstitutions = computed(() => {
    if (!filters.value.cluster) return props.institutions
    return props.institutions.filter(i => i.ClusterName === filters.value.cluster)
})

// FY is always set, so it is excluded from the "refine" affordances.
const activeFilterCount = computed(() =>
    ['cluster', 'institution', 'responsibility', 'account', 'period', 'group']
        .filter(k => filters.value[k] !== '' && filters.value[k] != null).length
)

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

const onClusterChange = () => {
    filters.value.institution = ''
    applyFilters()
}

const clearFilters = () => {
    filters.value = {
        cluster: '', institution: '', responsibility: '',
        account: '', period: '', group: '', fy: filters.value.fy,
    }
    applyFilters()
}

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
// Accounting style: negatives shown in parentheses, e.g. ($1,234.56). NetChange is
// netted of correcting entries, so a value can be negative (a reversal).
const formatCurrency = (value) => {
    const n = Number(value ?? 0)
    const s = new Intl.NumberFormat('en-TT', { style: 'currency', currency: 'TTD' })
        .format(Math.abs(n))
    return n < 0 ? `(${s})` : s
}

const isNegative = (value) => Number(value ?? 0) < 0

// Muted secondary category line, e.g. "GOODS AND SERVICES › MEDICAL, HARDWARE…".
const subGroupLine = (row) =>
    [row.SubGroupA, row.SubGroupB].filter(Boolean).join(' › ')
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
                A fiscal-year ledger of your monthly net expenditure by line.
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

            <!-- Total Net Expenditure -->
            <div class="bg-surface rounded-xl border border-line p-5 relative overflow-hidden shadow-sm">
                <div class="absolute top-0 left-0 bottom-0 w-1 rounded-l-xl" style="background: #d97706;"></div>
                <div class="pl-1">
                    <div class="flex items-start justify-between mb-3">
                        <div>
                            <p class="text-xs font-semibold text-tx-muted uppercase tracking-wider">Total Net Expenditure</p>
                            <p class="text-[10px] text-tx-subtle mt-0.5">Net of corrections · all filtered results</p>
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

            <!-- Highest Net Spend Month -->
            <div class="bg-surface rounded-xl border border-line p-5 relative overflow-hidden shadow-sm">
                <div class="absolute top-0 left-0 bottom-0 w-1 rounded-l-xl" style="background: #0ea5e9;"></div>
                <div class="pl-1">
                    <div class="flex items-start justify-between mb-3">
                        <div>
                            <p class="text-xs font-semibold text-tx-muted uppercase tracking-wider">Highest Net Spend Month</p>
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

            <!-- Top Net Spend Category -->
            <div class="bg-surface rounded-xl border border-line p-5 relative overflow-hidden shadow-sm">
                <div class="absolute top-0 left-0 bottom-0 w-1 rounded-l-xl" style="background: #6366f1;"></div>
                <div class="pl-1">
                    <div class="flex items-start justify-between mb-3">
                        <div>
                            <p class="text-xs font-semibold text-tx-muted uppercase tracking-wider">Top Net Spend Category</p>
                            <p class="text-[10px] text-tx-subtle mt-0.5 truncate max-w-[10rem]" :title="stats.topCategory?.label">
                                {{ stats.topCategory?.label || 'No category' }}
                            </p>
                        </div>
                        <div class="w-9 h-9 rounded-lg flex items-center justify-center flex-shrink-0" style="background: rgba(99,102,241,0.1);">
                            <i class="fas fa-layer-group text-sm" style="color: #4f46e5;"></i>
                        </div>
                    </div>
                    <p class="font-display text-3xl font-bold leading-none tabular-nums"
                        :class="isNegative(stats.topCategory?.amount) ? 'text-red-600 dark:text-red-400' : 'text-tx-primary'">
                        {{ formatCurrency(stats.topCategory?.amount) }}
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

            <div class="p-5 grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-6 gap-3">

                <div class="lg:col-span-2">
                    <label class="block text-xs font-medium text-tx-subtle mb-1">Cluster</label>
                    <select v-model="filters.cluster" @change="onClusterChange"
                        class="w-full rounded-lg border border-line-input bg-surface px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-amber-500/60 focus:border-transparent transition">
                        <option value="">All Clusters</option>
                        <option v-for="cluster in clusters" :key="cluster" :value="cluster">{{ cluster }}</option>
                    </select>
                </div>

                <div class="lg:col-span-2">
                    <label class="block text-xs font-medium text-tx-subtle mb-1">Institution</label>
                    <select v-model="filters.institution" @change="applyFilters"
                        class="w-full rounded-lg border border-line-input bg-surface px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-amber-500/60 focus:border-transparent transition">
                        <option value="">All Institutions</option>
                        <option v-for="inst in filteredInstitutions" :key="inst.InstitutionName" :value="inst.InstitutionName">
                            {{ inst.InstitutionName }}
                        </option>
                    </select>
                </div>

                <div class="lg:col-span-2">
                    <label class="block text-xs font-medium text-tx-subtle mb-1">Responsibility</label>
                    <select v-model="filters.responsibility" @change="applyFilters"
                        class="w-full rounded-lg border border-line-input bg-surface px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-amber-500/60 focus:border-transparent transition">
                        <option value="">All Responsibilities</option>
                        <option v-for="r in responsibilities" :key="r" :value="r">{{ r }}</option>
                    </select>
                </div>

                <div class="lg:col-span-2">
                    <label class="block text-xs font-medium text-tx-subtle mb-1">Month</label>
                    <select v-model="filters.period" @change="applyFilters"
                        class="w-full rounded-lg border border-line-input bg-surface px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-amber-500/60 focus:border-transparent transition">
                        <option value="">All Months</option>
                        <option v-for="m in months" :key="m.PeriodID" :value="String(m.PeriodID)">{{ m.TRXPeriod }}</option>
                    </select>
                </div>

                <div class="lg:col-span-2">
                    <label class="block text-xs font-medium text-tx-subtle mb-1">Category</label>
                    <select v-model="filters.group" @change="applyFilters"
                        class="w-full rounded-lg border border-line-input bg-surface px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-amber-500/60 focus:border-transparent transition">
                        <option value="">All Categories</option>
                        <option v-for="g in mainGroups" :key="g" :value="g">{{ g }}</option>
                    </select>
                </div>

                <div class="lg:col-span-2">
                    <label class="block text-xs font-medium text-tx-subtle mb-1">Account</label>
                    <select v-model="filters.account" @change="applyFilters"
                        class="w-full rounded-lg border border-line-input bg-surface px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-amber-500/60 focus:border-transparent transition">
                        <option value="">All Accounts</option>
                        <option v-for="acc in accounts" :key="acc.AccountNumber" :value="acc.AccountNumber">
                            {{ acc.AccountDescription }} ({{ acc.AccountNumber }})
                        </option>
                    </select>
                </div>

            </div>
        </div>

        <!-- ════════════════════════════ Results table ════════════════════════════ -->
        <div class="bg-surface rounded-xl shadow-sm border border-line overflow-hidden relative">

            <!-- Default label is already "Loading expenditure". -->
            <LedgerLoadingOverlay :show="loading" />

            <div class="overflow-x-auto">
                <table class="min-w-full divide-y divide-line">
                    <thead class="bg-surface-2">
                        <tr>
                            <th class="px-4 py-3 text-left text-[11px] font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">Year</th>
                            <th class="px-4 py-3 text-left text-[11px] font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">Month</th>
                            <th class="px-4 py-3 text-left text-[11px] font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">Cluster</th>
                            <th class="px-4 py-3 text-left text-[11px] font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">Institution</th>
                            <th class="px-4 py-3 text-left text-[11px] font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">Responsibility</th>
                            <th class="px-4 py-3 text-left text-[11px] font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">Account</th>
                            <th class="px-4 py-3 text-left text-[11px] font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">Category</th>
                            <th class="px-4 py-3 text-right text-[11px] font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">Net Change</th>
                        </tr>
                    </thead>
                    <tbody class="divide-y divide-line">

                        <!-- Empty state -->
                        <tr v-if="rows.data.length === 0">
                            <td colspan="8" class="px-4 py-16 text-center">
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

                        <!-- Data rows -->
                        <tr v-for="(row, index) in rows.data" :key="index"
                            class="group hover:bg-amber-50/40 dark:hover:bg-amber-900/10 transition-colors">
                            <td class="px-4 py-3 text-sm text-tx-primary whitespace-nowrap font-semibold tabular-nums">{{ row.FinancialYear ?? '—' }}</td>
                            <td class="px-4 py-3 text-sm text-tx-body whitespace-nowrap tabular-nums">{{ row.TRXPeriod ?? '—' }}</td>
                            <td class="px-4 py-3 text-sm text-tx-body whitespace-nowrap">{{ row.ClusterName ?? '—' }}</td>
                            <td class="px-4 py-3 text-sm text-tx-body whitespace-nowrap">{{ row.InstitutionName ?? '—' }}</td>
                            <td class="px-4 py-3 text-sm text-tx-body whitespace-nowrap">{{ row.Responsibility ?? '—' }}</td>
                            <td class="px-4 py-3 text-sm max-w-xs">
                                <div class="text-tx-body truncate" :title="row.AccountDescription">{{ row.AccountDescription ?? '—' }}</div>
                                <div class="text-[11px] text-tx-subtle font-mono">{{ row.AccountNumber ?? '—' }}</div>
                            </td>
                            <td class="px-4 py-3 text-sm max-w-xs">
                                <div class="text-tx-body truncate" :title="row.LineDescription">{{ row.MainGroup ?? '—' }}</div>
                                <div v-if="subGroupLine(row)" class="text-[11px] text-tx-subtle truncate" :title="subGroupLine(row)">
                                    {{ subGroupLine(row) }}
                                </div>
                            </td>
                            <td class="px-4 py-3 text-sm text-right whitespace-nowrap font-semibold tabular-nums"
                                :class="isNegative(row.NetChange) ? 'text-red-600 dark:text-red-400' : 'text-tx-primary'">
                                <span class="border-b border-transparent group-hover:border-amber-400/60 transition-colors">{{ formatCurrency(row.NetChange) }}</span>
                            </td>
                        </tr>

                    </tbody>
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
                            <span v-else
                                class="px-3 py-1.5 text-sm rounded-md opacity-40 text-tx-body">
                                <span v-html="link.label"></span>
                            </span>
                        </template>
                    </nav>
                </div>
            </div>

        </div>

    </div>
</template>

