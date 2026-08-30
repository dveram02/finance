<script setup>
import { ref, computed, onMounted, onUnmounted } from 'vue'
import { Head, Link, router } from '@inertiajs/vue3'
import NoAccessNotice from '@/Components/NoAccessNotice.vue'
import FiscalYearHero from '@/Components/FiscalYearHero.vue'
import ExportCsvButton from '@/Components/ExportCsvButton.vue'
import LedgerLoadingOverlay from '@/Components/LedgerLoadingOverlay.vue'
import { useFiscalYearNav } from '@/composables/useFiscalYearNav'

const props = defineProps({
    // False when the user maps to no department at all — a permanent state that
    // no retry or filter change fixes, so it must not read as "no results".
    hasAccess: { type: Boolean, default: true },
    allocations:       Object,
    clusters:          Array,
    institutions:      Array,
    responsibilities:  Array,
    departments:       Array,
    accounts:          Array,
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
    department:     props.filters.department     ?? '',
    account:        props.filters.account        ?? '',
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
    ['cluster', 'institution', 'responsibility', 'department', 'account']
        .filter(k => filters.value[k] !== '' && filters.value[k] != null).length
)

// ── Navigation helpers ──────────────────────────────────────────────────────────
// The filters the screen has applied. Shared by the Inertia visit and the
// export link so a CSV can never describe a different set of rows than the
// table above it. `page` is absent because it was never a filter.
const queryParams = computed(() => Object.fromEntries(
    Object.entries(filters.value).filter(([, v]) => v !== '' && v !== null)
))

// Guarded like SideBar.vue does: a missing Ziggy degrades to a disabled
// button rather than blanking the page.
const exportUrl = computed(() =>
    typeof route === 'function' ? route('budget-allocations.export', queryParams.value) : null
)

const exportRowCount = computed(() => props.stats?.total ?? 0)

const applyFilters = () => {
    router.get(route('budget-allocations.index'), queryParams.value, {
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
        department: '', account: '', fy: filters.value.fy,
    }
    applyFilters()
}

// ── Loading state (shown while a filter / FY / page reload is in flight) ─────────
// Driven by Inertia's global visit events so it covers the filter selects, the
// fiscal-year navigator, and the pagination links alike. The `start` guard keeps
// the spinner from flashing when the user navigates away to another page.
const loading = ref(false)
let stopOnStart = null
let stopOnFinish = null

onMounted(() => {
    stopOnStart = router.on('start', (event) => {
        const url = event.detail?.visit?.url
        if (!url || String(url.pathname ?? url).includes('budget-allocations')) {
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
</script>

<template>
    <Head title="Budget Allocations" />

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
            <h1 class="font-display text-3xl font-bold text-tx-primary tracking-tight">Budget Allocations</h1>
            <p class="text-sm text-tx-subtle mt-1">
                A fiscal-year ledger of your approved goods-and-services budget allocations.
            </p>
            <!-- The source view is restricted to the 41 reporting-line accounts, which
                 exclude salaries, overtime and benefits. Without saying so, the total
                 reads as a full departmental budget and is short by an order of magnitude. -->
            <p class="text-xs text-tx-subtle/80 mt-1">
                Payroll allocations (salaries, overtime, benefits) are not reported here.
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

            <!-- Total Records -->
            <div class="bg-surface rounded-xl border border-line p-5 relative overflow-hidden shadow-sm">
                <div class="absolute top-0 left-0 bottom-0 w-1 rounded-l-xl" style="background: #6366f1;"></div>
                <div class="pl-1">
                    <div class="flex items-start justify-between mb-3">
                        <div>
                            <p class="text-xs font-semibold text-tx-muted uppercase tracking-wider">Total Records</p>
                            <p class="text-[10px] text-tx-subtle mt-0.5">Matching the current filters</p>
                        </div>
                        <div class="w-9 h-9 rounded-lg flex items-center justify-center flex-shrink-0" style="background: rgba(99,102,241,0.1);">
                            <i class="fas fa-layer-group text-sm" style="color: #4f46e5;"></i>
                        </div>
                    </div>
                    <p class="font-display text-3xl font-bold text-tx-primary leading-none tabular-nums">{{ formatNumber(stats.total) }}</p>
                </div>
            </div>

            <!-- Largest Allocation -->
            <div class="bg-surface rounded-xl border border-line p-5 relative overflow-hidden shadow-sm">
                <div class="absolute top-0 left-0 bottom-0 w-1 rounded-l-xl" style="background: #0ea5e9;"></div>
                <div class="pl-1">
                    <div class="flex items-start justify-between mb-3">
                        <div>
                            <p class="text-xs font-semibold text-tx-muted uppercase tracking-wider">Largest Allocation</p>
                            <p class="text-[10px] text-tx-subtle mt-0.5 truncate max-w-[10rem]" :title="stats.largest?.label">
                                {{ stats.largest?.label || 'Single biggest line' }}
                            </p>
                        </div>
                        <div class="w-9 h-9 rounded-lg flex items-center justify-center flex-shrink-0" style="background: rgba(14,165,233,0.1);">
                            <i class="fas fa-arrow-up-wide-short text-sm" style="color: #0ea5e9;"></i>
                        </div>
                    </div>
                    <p class="text-[11px] font-semibold text-tx-muted mb-0.5">TTD</p>
                    <p class="font-display text-3xl font-bold text-tx-primary leading-none tabular-nums">
                        {{ formatNumber(Number(stats.largest?.amount ?? 0).toFixed(2)) }}
                    </p>
                </div>
            </div>

            <!-- Total Allocation -->
            <div class="bg-surface rounded-xl border border-line p-5 relative overflow-hidden shadow-sm">
                <div class="absolute top-0 left-0 bottom-0 w-1 rounded-l-xl" style="background: #d97706;"></div>
                <div class="pl-1">
                    <div class="flex items-start justify-between mb-3">
                        <div>
                            <p class="text-xs font-semibold text-tx-muted uppercase tracking-wider">Total Allocation</p>
                            <p class="text-[10px] text-tx-subtle mt-0.5">Goods and services, across all filtered results</p>
                        </div>
                        <div class="w-9 h-9 rounded-lg flex items-center justify-center flex-shrink-0" style="background: rgba(217,119,6,0.1);">
                            <i class="fas fa-coins text-sm" style="color: #d97706;"></i>
                        </div>
                    </div>
                    <p class="text-[11px] font-semibold text-tx-muted mb-0.5">TTD</p>
                    <p class="font-display text-3xl font-bold text-tx-primary leading-none tabular-nums">
                        {{ formatNumber(Number(stats.totalAllocation).toFixed(2)) }}
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
                <ExportCsvButton
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

                <div class="sm:col-span-2 lg:col-span-2">
                    <label class="block text-xs font-medium text-tx-subtle mb-1">Department</label>
                    <select v-model="filters.department" @change="applyFilters"
                        class="w-full rounded-lg border border-line-input bg-surface px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-amber-500/60 focus:border-transparent transition">
                        <option value="">All Departments</option>
                        <option v-for="dept in departments" :key="dept" :value="dept">{{ dept }}</option>
                    </select>
                </div>

                <div class="sm:col-span-2 lg:col-span-2">
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

            <LedgerLoadingOverlay :show="loading" label="Loading allocations" />

            <div class="overflow-x-auto">
                <table class="min-w-full divide-y divide-line">
                    <thead class="bg-surface-2">
                        <tr>
                            <th class="px-4 py-3 text-left text-[11px] font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">Year</th>
                            <th class="px-4 py-3 text-left text-[11px] font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">Cluster</th>
                            <th class="px-4 py-3 text-left text-[11px] font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">Institution</th>
                            <th class="px-4 py-3 text-left text-[11px] font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">Responsibility</th>
                            <th class="px-4 py-3 text-left text-[11px] font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">Department</th>
                            <th class="px-4 py-3 text-left text-[11px] font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">Account</th>
                            <th class="px-4 py-3 text-left text-[11px] font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">Account No.</th>
                            <th class="px-4 py-3 text-right text-[11px] font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">Total Allocation</th>
                        </tr>
                    </thead>
                    <tbody class="divide-y divide-line">

                        <!-- Empty state -->
                        <tr v-if="allocations.data.length === 0">
                            <td colspan="8" class="px-4 py-16 text-center">
                                <div class="inline-grid place-items-center h-14 w-14 rounded-full bg-surface-3 mb-3">
                                    <i class="fas fa-folder-open text-xl text-tx-muted"></i>
                                </div>
                                <p class="text-sm font-medium text-tx-body">
                                    {{ hasAccess ? 'No allocations found' : 'Department access is not configured' }}
                                </p>
                                <p v-if="hasAccess" class="text-xs text-tx-muted mt-1">
                                    Nothing in <span class="font-semibold">FY {{ activeFiscalYear }}</span>
                                    <template v-if="activeFilterCount"> matching your filters</template>.
                                </p>
                            </td>
                        </tr>

                        <!-- Data rows -->
                        <tr v-for="(row, index) in allocations.data" :key="index"
                            class="group hover:bg-amber-50/40 dark:hover:bg-amber-900/10 transition-colors">
                            <td class="px-4 py-3 text-sm text-tx-primary whitespace-nowrap font-semibold tabular-nums">{{ row.FinancialYear ?? '—' }}</td>
                            <td class="px-4 py-3 text-sm text-tx-body whitespace-nowrap">{{ row.ClusterName ?? '—' }}</td>
                            <td class="px-4 py-3 text-sm text-tx-body whitespace-nowrap">{{ row.InstitutionName ?? '—' }}</td>
                            <td class="px-4 py-3 text-sm text-tx-body whitespace-nowrap">{{ row.ResponsibilityName ?? '—' }}</td>
                            <td class="px-4 py-3 text-sm text-tx-body whitespace-nowrap">{{ row.DepartmentName ?? '—' }}</td>
                            <td class="px-4 py-3 text-sm text-tx-body max-w-xs truncate" :title="row.AccountDescription">{{ row.AccountDescription ?? '—' }}</td>
                            <td class="px-4 py-3 text-sm text-tx-subtle font-mono whitespace-nowrap">{{ row.AccountNumber ?? '—' }}</td>
                            <td class="px-4 py-3 text-sm text-tx-primary text-right whitespace-nowrap font-semibold tabular-nums">
                                <span class="border-b border-transparent group-hover:border-amber-400/60 transition-colors">{{ formatCurrency(row.TotalAllocation) }}</span>
                            </td>
                        </tr>

                    </tbody>
                </table>
            </div>

            <!-- Pagination -->
            <div v-if="allocations.total > 0" class="bg-surface-2 px-4 py-3 border-t border-line">
                <div class="flex flex-col sm:flex-row items-center justify-between gap-4">
                    <p class="text-sm text-tx-body">
                        Showing <span class="font-semibold text-tx-primary">{{ allocations.from }}</span> to
                        <span class="font-semibold text-tx-primary">{{ allocations.to }}</span> of
                        <span class="font-semibold text-tx-primary">{{ allocations.total }}</span> results
                    </p>
                    <nav v-if="allocations.last_page > 1" class="flex items-center gap-1">
                        <template v-for="link in allocations.links" :key="link.label">
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

