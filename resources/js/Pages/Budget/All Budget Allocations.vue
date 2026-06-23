<script setup>
import { ref, computed, onMounted, onUnmounted, nextTick } from 'vue'
import { Head, Link, router } from '@inertiajs/vue3'

const props = defineProps({
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
const activeYearStr = computed(() => String(props.activeFiscalYear ?? ''))

const isCurrentFiscalYear = computed(() =>
    String(props.activeFiscalYear) === String(props.currentFiscalYear)
)

// Fiscal year N runs Oct (N-1) → Sep N.
const fiscalYearSpan = computed(() => {
    const fy = Number(props.activeFiscalYear)
    if (!fy) return ''
    return `Oct ${fy - 1} – Sep ${fy}`
})

const goToFy = (fy) => {
    if (fy === null || fy === undefined) return
    if (String(fy) === activeYearStr.value) return
    filters.value.fy = String(fy)
    applyFilters()
}

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
const applyFilters = () => {
    const params = Object.fromEntries(
        Object.entries(filters.value).filter(([, v]) => v !== '' && v !== null)
    )
    router.get(route('budget-allocations.index'), params, {
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

// ── Year rail: auto-scroll active year into view ────────────────────────────────
const yearRail = ref(null)

const scrollActiveIntoView = () => {
    nextTick(() => {
        const el = yearRail.value?.querySelector('[data-active="true"]')
        el?.scrollIntoView({ inline: 'center', block: 'nearest', behavior: 'smooth' })
    })
}

// ── Keyboard navigation (← / → between fiscal years) ────────────────────────────
const handleKeydown = (e) => {
    const tag = document.activeElement?.tagName
    if (tag === 'SELECT' || tag === 'INPUT' || tag === 'TEXTAREA') return

    if (e.key === 'ArrowLeft' && props.fyNav?.prev != null) {
        e.preventDefault()
        goToFy(props.fyNav.prev)
    } else if (e.key === 'ArrowRight' && props.fyNav?.next != null) {
        e.preventDefault()
        goToFy(props.fyNav.next)
    }
}

// ── Loading state (shown while a filter / FY / page reload is in flight) ─────────
// Driven by Inertia's global visit events so it covers the filter selects, the
// fiscal-year navigator, and the pagination links alike. The `start` guard keeps
// the spinner from flashing when the user navigates away to another page.
const loading = ref(false)
let stopOnStart = null
let stopOnFinish = null

onMounted(() => {
    window.addEventListener('keydown', handleKeydown)
    scrollActiveIntoView()

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
    window.removeEventListener('keydown', handleKeydown)
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
                A fiscal-year ledger of your approved budget allocations.
            </p>
        </div>

        <!-- ═══════════════════ Fiscal Year navigator (the hero) ═══════════════════ -->
        <section class="relative overflow-hidden rounded-2xl border border-white/60 shadow-xl shadow-slate-950/8 dark:border-white/10">
            <div class="absolute inset-0 bg-gradient-to-br from-cyan-50 via-white to-slate-100 dark:from-[#0b1625] dark:via-[#14213d] dark:to-[#0b1625]"></div>
            <!-- Radial dot texture -->
            <div class="absolute inset-0 opacity-[0.18] dark:hidden"
                style="background-image: radial-gradient(circle at 1px 1px, rgba(8,47,73,0.45) 1px, transparent 0); background-size: 22px 22px;"></div>
            <div class="absolute inset-0 hidden opacity-[0.06] dark:block"
                style="background-image: radial-gradient(circle at 1px 1px, rgba(255,255,255,0.5) 1px, transparent 0); background-size: 22px 22px;"></div>
            <!-- Gold filament along the top edge -->
            <div class="absolute top-0 inset-x-0 h-px"
                style="background: linear-gradient(90deg, transparent, #d97706 25%, #fbbf24 50%, #d97706 75%, transparent);"></div>
            <!-- Soft gold glow behind the numeral -->
            <div class="pointer-events-none absolute left-1/2 top-1/2 -translate-x-1/2 -translate-y-[150%] h-28 w-28 rounded-full blur-3xl"
                style="background: radial-gradient(circle, rgba(251,191,36,0.16), transparent 70%);"></div>

            <div class="relative px-6 sm:px-10 py-3.5">

                <!-- Eyebrow row -->
                <div class="flex items-center justify-between gap-4">
                    <span class="inline-flex items-center gap-2 text-[11px] font-semibold uppercase tracking-[0.22em] text-cyan-800 dark:text-amber-300/90">
                        <i class="fas fa-calendar-day text-[10px]"></i>
                        Fiscal Year
                    </span>
                    <span v-if="isCurrentFiscalYear"
                        class="inline-flex items-center gap-1.5 rounded-full bg-amber-100 ring-1 ring-amber-300/70 px-2.5 py-1 text-[10px] font-bold uppercase tracking-wider text-amber-800 dark:bg-amber-400/15 dark:ring-amber-300/40 dark:text-amber-200">
                        <span class="relative flex h-1.5 w-1.5">
                            <span class="absolute inline-flex h-full w-full animate-ping rounded-full bg-amber-300 opacity-75"></span>
                            <span class="relative inline-flex h-1.5 w-1.5 rounded-full bg-amber-300"></span>
                        </span>
                        Current
                    </span>
                </div>

                <!-- Stepper: prev · numeral · next -->
                <div class="mt-2 flex items-center justify-center gap-5 sm:gap-8">
                    <button
                        @click="goToFy(fyNav?.prev)" :disabled="!fyNav?.prev"
                        title="Previous fiscal year (←)" aria-label="Previous fiscal year"
                        class="group flex-shrink-0 grid place-items-center h-9 w-9 rounded-full border border-cyan-700/15 bg-white/60 text-cyan-800 backdrop-blur-sm transition hover:border-amber-400/60 hover:text-amber-700 hover:bg-white disabled:opacity-25 disabled:cursor-not-allowed dark:border-white/15 dark:bg-white/5 dark:text-blue-100/80 dark:hover:border-amber-300/50 dark:hover:text-amber-200 dark:hover:bg-white/10 dark:disabled:hover:border-white/15 dark:disabled:hover:text-blue-100/80 dark:disabled:hover:bg-white/5">
                        <i class="fas fa-chevron-left transition-transform group-hover:-translate-x-0.5"></i>
                    </button>

                    <div class="text-center min-w-[7rem] sm:min-w-[9rem]">
                        <div class="relative inline-block leading-none">
                            <transition name="fy" mode="out-in">
                                <span :key="activeYearStr"
                                    class="fy-numeral font-display block text-5xl font-bold text-slate-950 tabular-nums dark:text-white">
                                    {{ activeFiscalYear || '—' }}
                                </span>
                            </transition>
                        </div>
                        <p class="mt-1 text-xs font-medium text-slate-600 tracking-wide dark:text-blue-100/60">
                            {{ fiscalYearSpan }}
                        </p>
                    </div>

                    <button
                        @click="goToFy(fyNav?.next)" :disabled="!fyNav?.next"
                        title="Next fiscal year (→)" aria-label="Next fiscal year"
                        class="group flex-shrink-0 grid place-items-center h-9 w-9 rounded-full border border-cyan-700/15 bg-white/60 text-cyan-800 backdrop-blur-sm transition hover:border-amber-400/60 hover:text-amber-700 hover:bg-white disabled:opacity-25 disabled:cursor-not-allowed dark:border-white/15 dark:bg-white/5 dark:text-blue-100/80 dark:hover:border-amber-300/50 dark:hover:text-amber-200 dark:hover:bg-white/10 dark:disabled:hover:border-white/15 dark:disabled:hover:text-blue-100/80 dark:disabled:hover:bg-white/5">
                        <i class="fas fa-chevron-right transition-transform group-hover:translate-x-0.5"></i>
                    </button>
                </div>

                <!-- Year rail -->
                <div v-if="years.length" class="mt-3">
                    <div ref="yearRail"
                        role="tablist" aria-label="Select fiscal year"
                        class="year-rail flex items-center justify-center gap-2 overflow-x-auto pb-1 -mx-1 px-1">
                        <button v-for="year in years" :key="year"
                            role="tab"
                            :data-active="String(year) === activeYearStr"
                            :aria-selected="String(year) === activeYearStr"
                            @click="goToFy(year)"
                            :class="[
                                'flex-shrink-0 rounded-full px-3.5 py-1 text-sm font-semibold tabular-nums transition-all duration-200',
                                String(year) === activeYearStr
                                    ? 'bg-gradient-to-b from-amber-300 to-amber-500 text-[#1a1205] shadow-lg shadow-amber-500/20'
                                    : 'bg-white/70 text-cyan-800 ring-1 ring-cyan-700/10 hover:bg-cyan-50 hover:text-cyan-950 dark:bg-white/5 dark:text-blue-100/70 dark:ring-white/10 dark:hover:bg-white/10 dark:hover:text-white',
                                String(year) === String(currentFiscalYear) && String(year) !== activeYearStr
                                    ? 'ring-1 ring-dashed ring-amber-300/50' : '',
                            ]">
                            {{ year }}
                        </button>
                    </div>
                </div>

            </div>
        </section>

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
                            <p class="text-[10px] text-tx-subtle mt-0.5">Across all filtered results</p>
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

            <!-- Loading overlay — financial coin spinner while a visit is in flight -->
            <transition name="overlay">
                <div v-if="loading"
                    class="absolute inset-0 z-20 grid place-items-center bg-surface/70 backdrop-blur-[2px]">
                    <div class="flex flex-col items-center gap-4">
                        <div class="coin" aria-hidden="true">
                            <div class="coin__face coin__front">$</div>
                            <div class="coin__face coin__back">$</div>
                        </div>
                        <p class="text-[11px] font-semibold uppercase tracking-[0.22em] text-tx-subtle">
                            Loading allocations<span class="loading-dots"></span>
                        </p>
                    </div>
                </div>
            </transition>

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
                                <p class="text-sm font-medium text-tx-body">No allocations found</p>
                                <p class="text-xs text-tx-muted mt-1">
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

<style scoped>
/* Fiscal-year numeral transition — replays on every year change via :key */
.fy-enter-active {
    animation: fyIn 0.45s cubic-bezier(0.16, 1, 0.3, 1);
}
.fy-leave-active {
    animation: fyOut 0.2s ease-in forwards;
}
@keyframes fyIn {
    0%   { opacity: 0; transform: translateY(0.35em) scale(0.94); filter: blur(6px); }
    100% { opacity: 1; transform: translateY(0)     scale(1);    filter: blur(0); }
}
@keyframes fyOut {
    0%   { opacity: 1; transform: translateY(0)      scale(1); }
    100% { opacity: 0; transform: translateY(-0.3em) scale(0.97); }
}

/* Slim year-rail scrollbar */
.year-rail::-webkit-scrollbar {
    height: 5px;
}
.year-rail::-webkit-scrollbar-track {
    background: transparent;
}
.year-rail::-webkit-scrollbar-thumb {
    background: rgba(251, 191, 36, 0.28);
    border-radius: 9999px;
}
.year-rail::-webkit-scrollbar-thumb:hover {
    background: rgba(251, 191, 36, 0.5);
}

/* ── Loading overlay fade ──────────────────────────────────────────────────── */
.overlay-enter-active,
.overlay-leave-active {
    transition: opacity 0.2s ease;
}
.overlay-enter-from,
.overlay-leave-to {
    opacity: 0;
}

/* ── Financial coin spinner ────────────────────────────────────────────────── */
/* A minted gold coin flipping on its vertical axis. Two faces with hidden
   backfaces keep the "$" upright through the whole rotation; the coin bobs
   gently so it reads as 3-D rather than a flat spin. */
.coin {
    position: relative;
    width: 58px;
    height: 58px;
    transform-style: preserve-3d;
    animation: coinFlip 1.5s cubic-bezier(0.45, 0, 0.55, 1) infinite,
               coinBob 1.5s ease-in-out infinite;
    filter: drop-shadow(0 10px 12px rgba(180, 83, 9, 0.28));
}

.coin__face {
    position: absolute;
    inset: 0;
    display: grid;
    place-items: center;
    border-radius: 9999px;
    font-family: 'Playfair Display', Georgia, serif;
    font-weight: 700;
    font-size: 1.5rem;
    color: #7c2d12;
    backface-visibility: hidden;
    background:
        radial-gradient(circle at 34% 28%, #fffbeb 0%, #fde68a 26%, #f59e0b 62%, #d97706 84%, #b45309 100%);
    box-shadow:
        inset 0 2px 3px rgba(255, 255, 255, 0.65),
        inset 0 -4px 7px rgba(120, 53, 15, 0.5),
        inset 0 0 0 4px rgba(180, 83, 9, 0.28);   /* milled rim */
}

.coin__back {
    transform: rotateY(180deg);
}

@keyframes coinFlip {
    0%   { transform: rotateY(0deg); }
    100% { transform: rotateY(360deg); }
}

@keyframes coinBob {
    0%, 100% { translate: 0 0; }
    50%      { translate: 0 -5px; }
}

/* Animated trailing dots on the label */
.loading-dots::after {
    content: '';
    animation: loadingDots 1.4s steps(1, end) infinite;
}

@keyframes loadingDots {
    0%   { content: ''; }
    25%  { content: '.'; }
    50%  { content: '..'; }
    75%  { content: '...'; }
    100% { content: ''; }
}

@media (prefers-reduced-motion: reduce) {
    .coin {
        animation: coinFlip 2.4s linear infinite;
    }
    .loading-dots::after {
        animation: none;
        content: '…';
    }
}
</style>
