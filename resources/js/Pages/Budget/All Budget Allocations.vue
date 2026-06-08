<script setup>
import { ref, computed } from 'vue'
import { Head, Link, router } from '@inertiajs/vue3'

const props = defineProps({
    allocations:      Object,
    clusters:         Array,
    institutions:     Array,
    responsibilities: Array,
    departments:      Array,
    accounts:         Array,
    years:            Array,
    stats:            Object,
    filters:          Object,
})

// ── Filter state ──────────────────────────────────────────────────────────────
const filters = ref({
    cluster:        props.filters.cluster        ?? '',
    institution:    props.filters.institution    ?? '',
    responsibility: props.filters.responsibility ?? '',
    department:     props.filters.department     ?? '',
    account:        props.filters.account        ?? '',
    year_from:      props.filters.year_from      ?? '',
    year_to:        props.filters.year_to        ?? '',
})

// ── Institution cascade ───────────────────────────────────────────────────────
const filteredInstitutions = computed(() => {
    if (!filters.value.cluster) return props.institutions
    return props.institutions.filter(i => i.ClusterName === filters.value.cluster)
})

const hasActiveFilters = computed(() =>
    Object.values(filters.value).some(v => v !== '' && v !== null && v !== undefined)
)

// ── Navigation helpers ────────────────────────────────────────────────────────
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
        department: '', account: '', year_from: '', year_to: '',
    }
    applyFilters()
}

// ── Formatting ────────────────────────────────────────────────────────────────
const formatCurrency = (value) =>
    new Intl.NumberFormat('en-TT', { style: 'currency', currency: 'TTD' }).format(value ?? 0)

const formatNumber = (value) =>
    Number(value ?? 0).toLocaleString('en-TT')
</script>

<template>
    <Head title="Budget Allocations" />

    <main class="min-h-screen bg-surface-2 py-6 px-4 sm:px-6 lg:px-8">
        <div class="mx-auto max-w-7xl space-y-6">

            <!-- Flash messages -->
            <div v-if="$page.props.flash?.success"
                class="p-4 bg-green-50 border border-green-200 rounded-lg flex items-start gap-3 dark:bg-green-900/20 dark:border-green-800">
                <svg class="w-5 h-5 text-green-500 flex-shrink-0 mt-0.5" fill="currentColor" viewBox="0 0 20 20">
                    <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z" clip-rule="evenodd"/>
                </svg>
                <p class="text-sm text-green-800 dark:text-green-200">{{ $page.props.flash.success }}</p>
            </div>

            <div v-if="$page.props.flash?.error"
                class="p-4 bg-red-50 border border-red-200 rounded-lg flex items-start gap-3 dark:bg-red-900/20 dark:border-red-800">
                <svg class="w-5 h-5 text-red-500 flex-shrink-0 mt-0.5" fill="currentColor" viewBox="0 0 20 20">
                    <path fill-rule="evenodd" d="M10 18a8 8 0 100-16 8 8 0 000 16zm-1-9v4a1 1 0 102 0V9a1 1 0 10-2 0zm0-4a1 1 0 112 0 1 1 0 01-2 0z" clip-rule="evenodd"/>
                </svg>
                <p class="text-sm text-red-800 dark:text-red-200">{{ $page.props.flash.error }}</p>
            </div>

            <div v-if="$page.props.flash?.warning"
                class="p-4 bg-amber-50 border border-amber-200 rounded-lg flex items-start gap-3 dark:bg-amber-900/20 dark:border-amber-800">
                <svg class="w-5 h-5 text-amber-500 flex-shrink-0 mt-0.5" fill="currentColor" viewBox="0 0 20 20">
                    <path fill-rule="evenodd" d="M8.257 3.099c.765-1.36 2.722-1.36 3.486 0l5.58 9.92c.75 1.334-.213 2.98-1.742 2.98H4.42c-1.53 0-2.493-1.646-1.743-2.98l5.58-9.92zM11 13a1 1 0 11-2 0 1 1 0 012 0zm-1-8a1 1 0 00-1 1v3a1 1 0 002 0V6a1 1 0 00-1-1z" clip-rule="evenodd"/>
                </svg>
                <p class="text-sm text-amber-800 dark:text-amber-200">{{ $page.props.flash.warning }}</p>
            </div>

            <!-- Page header -->
            <div class="flex flex-col sm:flex-row items-start sm:items-center justify-between gap-4">
                <div>
                    <h1 class="text-2xl font-bold text-tx-primary">Budget Allocations</h1>
                    <p class="text-sm text-tx-subtle mt-1">View your approved budget allocations by financial year.</p>
                </div>
            </div>

            <!-- KPI cards -->
            <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">

                <div class="bg-surface rounded-lg shadow-sm border border-line p-5 relative overflow-hidden">
                    <div class="absolute top-0 left-0 bottom-0 w-1 rounded-l-lg bg-slate-500"></div>
                    <div class="pl-1">
                        <div class="flex items-start justify-between mb-2">
                            <p class="text-xs font-semibold text-tx-muted uppercase tracking-wider">Total Records</p>
                            <div class="w-8 h-8 rounded-lg flex items-center justify-center bg-slate-100 dark:bg-slate-800">
                                <i class="fas fa-list text-xs text-slate-500"></i>
                            </div>
                        </div>
                        <p class="text-2xl font-bold text-tx-primary">{{ formatNumber(stats.total) }}</p>
                        <p class="text-xs text-tx-subtle mt-1">matching your current filters</p>
                    </div>
                </div>

                <div class="bg-surface rounded-lg shadow-sm border border-line p-5 relative overflow-hidden">
                    <div class="absolute top-0 left-0 bottom-0 w-1 rounded-l-lg bg-teal-500"></div>
                    <div class="pl-1">
                        <div class="flex items-start justify-between mb-2">
                            <p class="text-xs font-semibold text-tx-muted uppercase tracking-wider">Total Allocation</p>
                            <div class="w-8 h-8 rounded-lg flex items-center justify-center bg-teal-50 dark:bg-teal-900/30">
                                <i class="fas fa-coins text-xs text-teal-600 dark:text-teal-400"></i>
                            </div>
                        </div>
                        <p class="text-2xl font-bold text-tx-primary">{{ formatCurrency(stats.totalAllocation) }}</p>
                        <p class="text-xs text-tx-subtle mt-1">across all filtered results</p>
                    </div>
                </div>

            </div>

            <!-- Filter bar -->
            <div class="bg-surface rounded-lg shadow-sm border border-line p-4">
                <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-3">

                    <!-- Cluster -->
                    <div>
                        <label class="block text-xs font-medium text-tx-subtle mb-1">Cluster</label>
                        <select v-model="filters.cluster" @change="onClusterChange"
                            class="w-full rounded-lg border border-line-input bg-surface px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:border-transparent transition">
                            <option value="">All Clusters</option>
                            <option v-for="cluster in clusters" :key="cluster" :value="cluster">{{ cluster }}</option>
                        </select>
                    </div>

                    <!-- Institution (cascades from cluster) -->
                    <div>
                        <label class="block text-xs font-medium text-tx-subtle mb-1">Institution</label>
                        <select v-model="filters.institution" @change="applyFilters"
                            class="w-full rounded-lg border border-line-input bg-surface px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:border-transparent transition">
                            <option value="">All Institutions</option>
                            <option v-for="inst in filteredInstitutions" :key="inst.InstitutionName" :value="inst.InstitutionName">
                                {{ inst.InstitutionName }}
                            </option>
                        </select>
                    </div>

                    <!-- Responsibility -->
                    <div>
                        <label class="block text-xs font-medium text-tx-subtle mb-1">Responsibility</label>
                        <select v-model="filters.responsibility" @change="applyFilters"
                            class="w-full rounded-lg border border-line-input bg-surface px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:border-transparent transition">
                            <option value="">All Responsibilities</option>
                            <option v-for="r in responsibilities" :key="r" :value="r">{{ r }}</option>
                        </select>
                    </div>

                    <!-- Department -->
                    <div>
                        <label class="block text-xs font-medium text-tx-subtle mb-1">Department</label>
                        <select v-model="filters.department" @change="applyFilters"
                            class="w-full rounded-lg border border-line-input bg-surface px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:border-transparent transition">
                            <option value="">All Departments</option>
                            <option v-for="dept in departments" :key="dept" :value="dept">{{ dept }}</option>
                        </select>
                    </div>

                    <!-- Account (spans 2 cols on large screens) -->
                    <div class="lg:col-span-2">
                        <label class="block text-xs font-medium text-tx-subtle mb-1">Account</label>
                        <select v-model="filters.account" @change="applyFilters"
                            class="w-full rounded-lg border border-line-input bg-surface px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:border-transparent transition">
                            <option value="">All Accounts</option>
                            <option v-for="acc in accounts" :key="acc.AccountNumber" :value="acc.AccountNumber">
                                {{ acc.AccountDescription }} ({{ acc.AccountNumber }})
                            </option>
                        </select>
                    </div>

                    <!-- Year From -->
                    <div>
                        <label class="block text-xs font-medium text-tx-subtle mb-1">Year From</label>
                        <select v-model="filters.year_from" @change="applyFilters"
                            class="w-full rounded-lg border border-line-input bg-surface px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:border-transparent transition">
                            <option value="">Any Year</option>
                            <option v-for="year in years" :key="year" :value="year">{{ year }}</option>
                        </select>
                    </div>

                    <!-- Year To + Clear button -->
                    <div class="flex gap-2 items-end">
                        <div class="flex-1">
                            <label class="block text-xs font-medium text-tx-subtle mb-1">Year To</label>
                            <select v-model="filters.year_to" @change="applyFilters"
                                class="w-full rounded-lg border border-line-input bg-surface px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:border-transparent transition">
                                <option value="">Any Year</option>
                                <option v-for="year in years" :key="year" :value="year">{{ year }}</option>
                            </select>
                        </div>
                        <button v-if="hasActiveFilters" @click="clearFilters" title="Clear all filters"
                            class="flex-shrink-0 inline-flex items-center justify-center w-9 h-9 rounded-lg border border-line-input bg-surface text-tx-subtle hover:text-red-500 hover:border-red-300 hover:bg-red-50 transition mb-0">
                            <i class="fas fa-times text-sm"></i>
                        </button>
                    </div>

                </div>
            </div>

            <!-- Results table -->
            <div class="bg-surface rounded-lg shadow-sm border border-line overflow-hidden">
                <div class="overflow-x-auto">
                    <table class="min-w-full divide-y divide-line">
                        <thead class="bg-surface-2">
                            <tr>
                                <th class="px-4 py-3 text-left text-xs font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">
                                    Year
                                </th>
                                <th class="px-4 py-3 text-left text-xs font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">
                                    Cluster
                                </th>
                                <th class="px-4 py-3 text-left text-xs font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">
                                    Institution
                                </th>
                                <th class="px-4 py-3 text-left text-xs font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">
                                    Responsibility
                                </th>
                                <th class="px-4 py-3 text-left text-xs font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">
                                    Department
                                </th>
                                <th class="px-4 py-3 text-left text-xs font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">
                                    Account
                                </th>
                                <th class="px-4 py-3 text-left text-xs font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">
                                    Account No.
                                </th>
                                <th class="px-4 py-3 text-right text-xs font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">
                                    Total Allocation
                                </th>
                            </tr>
                        </thead>
                        <tbody class="divide-y divide-line">

                            <!-- Empty state -->
                            <tr v-if="allocations.data.length === 0">
                                <td colspan="8" class="px-4 py-12 text-center">
                                    <i class="fas fa-inbox text-4xl text-tx-muted mb-3 block"></i>
                                    <p class="text-sm font-medium text-tx-subtle">No allocations found.</p>
                                    <p class="text-xs text-tx-muted mt-1">Try adjusting your filters.</p>
                                </td>
                            </tr>

                            <!-- Data rows -->
                            <tr v-for="(row, index) in allocations.data" :key="index"
                                class="hover:bg-surface-2 transition">
                                <td class="px-4 py-3 text-sm text-tx-primary whitespace-nowrap font-medium">
                                    {{ row.FinancialYear ?? '—' }}
                                </td>
                                <td class="px-4 py-3 text-sm text-tx-body whitespace-nowrap">
                                    {{ row.ClusterName ?? '—' }}
                                </td>
                                <td class="px-4 py-3 text-sm text-tx-body whitespace-nowrap">
                                    {{ row.InstitutionName ?? '—' }}
                                </td>
                                <td class="px-4 py-3 text-sm text-tx-body whitespace-nowrap">
                                    {{ row.ResponsibilityName ?? '—' }}
                                </td>
                                <td class="px-4 py-3 text-sm text-tx-body whitespace-nowrap">
                                    {{ row.DepartmentName ?? '—' }}
                                </td>
                                <td class="px-4 py-3 text-sm text-tx-body">
                                    {{ row.AccountDescription ?? '—' }}
                                </td>
                                <td class="px-4 py-3 text-sm text-tx-subtle font-mono whitespace-nowrap">
                                    {{ row.AccountNumber ?? '—' }}
                                </td>
                                <td class="px-4 py-3 text-sm text-tx-primary text-right whitespace-nowrap font-medium tabular-nums">
                                    {{ formatCurrency(row.TotalAllocation) }}
                                </td>
                            </tr>

                        </tbody>
                    </table>
                </div>

                <!-- Pagination -->
                <div v-if="allocations.last_page > 1" class="bg-surface-2 px-4 py-3 border-t border-line">
                    <div class="flex flex-col sm:flex-row items-center justify-between gap-4">
                        <p class="text-sm text-tx-body">
                            Showing <span class="font-medium">{{ allocations.from }}</span> to
                            <span class="font-medium">{{ allocations.to }}</span> of
                            <span class="font-medium">{{ allocations.total }}</span> results
                        </p>
                        <nav class="flex items-center gap-1">
                            <template v-for="link in allocations.links" :key="link.label">
                                <Link v-if="link.url" :href="link.url" preserve-scroll
                                    :class="['px-3 py-1.5 text-sm rounded-md transition',
                                        link.active ? 'bg-indigo-600 text-white' : 'text-tx-body hover:bg-surface-3']">
                                    <span v-html="link.label"></span>
                                </Link>
                                <span v-else
                                    :class="['px-3 py-1.5 text-sm rounded-md opacity-40',
                                        link.active ? 'bg-indigo-600 text-white' : 'text-tx-body']">
                                    <span v-html="link.label"></span>
                                </span>
                            </template>
                        </nav>
                    </div>
                </div>

            </div>

        </div>
    </main>
</template>
