<script setup>
import { computed, ref, onMounted, onUnmounted } from 'vue'
import { Head, router } from '@inertiajs/vue3'
import { useDarkMode } from '@/composables/useDarkMode'
import {
  Chart as ChartJS,
  Title,
  Tooltip,
  Legend,
  BarElement,
  LineElement,
  PointElement,
  CategoryScale,
  LinearScale,
  Filler,
} from 'chart.js'
import { Bar, Line } from 'vue-chartjs'

ChartJS.register(
  Title,
  Tooltip,
  Legend,
  BarElement,
  LineElement,
  PointElement,
  CategoryScale,
  LinearScale,
  Filler,
)

import NoAccessNotice from '@/Components/NoAccessNotice.vue'
import FiscalYearHero from '@/Components/FiscalYearHero.vue'
import ExportCsvButton from '@/Components/ExportCsvButton.vue'
import LedgerLoadingOverlay from '@/Components/LedgerLoadingOverlay.vue'

const { isDark } = useDarkMode()

const props = defineProps({
  userName: String,
  // False when the user maps to no department at all. Distinct from the
  // *Available flags: nothing is broken, so the copy must not say it is.
  hasAccess: { type: Boolean, default: true },
  fiscalYear: Number,
  // Same value as fiscalYear, under the name FiscalYearHero and every sibling
  // page use. Kept as an alias so the shared control drops in unmapped.
  activeFiscalYear: [Number, String],
  currentFiscalYear: [Number, String],
  // Scoped to years with BUDGET data — this page is budget-vs-actual, so a
  // year with spend but no allocation baseline has nothing to compare against.
  years: { type: Array, default: () => [] },
  fyNav: { type: Object, default: () => ({ prev: null, next: null }) },
  totalBudget: Number,
  budgetAvailable: { type: Boolean, default: true },
  expenditureAvailable: { type: Boolean, default: true },
  expenditureWindowStarted: { type: Boolean, default: true },
  ytdExpenditure: Number,
  latestPeriodLabel: String,
  monthlyExpenditure: Object,
  budgetVsActual: Object,
  expenditureByCategory: Object,
})

// ── Fiscal year navigation ────────────────────────────────────────────────────
// The dashboard carries no other filters, so a year change is a bare visit.
// preserveState keeps the Chart.js instances alive across the swap.
const goToFy = (fy) => router.get(route('dashboard'), { fy: String(fy) }, {
  preserveState: true,
  preserveScroll: true,
  replace: true,
})

// Arrow keys do NOT step the fiscal year. A global ← → handler lived here
// until 2026-10-02 (useFiscalYearNav, now deleted): it renavigated the page
// from anywhere, which is not something a reader can predict. The year is
// changed by the hero's stepper and rail, which emit `select`.

// ── Export ────────────────────────────────────────────────────────────────────
// The active year is the only scope this page has. Guarded like SideBar.vue
// does: a missing Ziggy degrades to a disabled button, not a blank page.
const exportUrl = computed(() =>
  typeof route === 'function'
    ? route('dashboard.export', { fy: String(props.activeFiscalYear ?? '') })
    : null
)

// Every figure on the page is fiscal-year scoped, so a year change re-queries
// SQL Server. Without this the page looks frozen on a cold cache.
const loading = ref(false)
let stopOnStart = null
let stopOnFinish = null

onMounted(() => {
  stopOnStart = router.on('start', (event) => {
    const url = event.detail?.visit?.url
    if (!url || String(url.pathname ?? url).includes('dashboard')) {
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

// A completed year's total is not a "year to date" figure, and a year that has
// not begun has no figure at all.
const isPastFy = computed(() =>
  Number(props.activeFiscalYear) < Number(props.currentFiscalYear))

const expenditureCardTitle = computed(() => {
  if (!props.expenditureWindowStarted) return 'Expenditure'
  return isPastFy.value ? 'Total Expenditure' : 'YTD Expenditure'
})

// ── Currency helpers ──────────────────────────────────────────────────────────
const formatCurrency = (value) =>
  'TTD ' + Number(value ?? 0).toLocaleString('en-TT', { minimumFractionDigits: 2, maximumFractionDigits: 2 })

const formatAmount = (value) =>
  Number(value ?? 0).toLocaleString('en-TT', { minimumFractionDigits: 2, maximumFractionDigits: 2 })

// ── Today's date ──────────────────────────────────────────────────────────────
const today = new Date().toLocaleDateString('en-TT', { year: 'numeric', month: 'long', day: 'numeric' })

// ── KPI computations ──────────────────────────────────────────────────────────
// YTD net expenditure comes straight from the controller (single source of truth);
// it equals the final point of the cumulative Actual line.
const totalExpenditure = computed(() => props.ytdExpenditure ?? 0)
const totalBudget = computed(() => props.totalBudget ?? 0)
const variance = computed(() => totalBudget.value - totalExpenditure.value)
const overBudget = computed(() => totalBudget.value > 0 && totalExpenditure.value > totalBudget.value)
const overage = computed(() => Math.max(0, totalExpenditure.value - totalBudget.value))

// Capped at 100% for display — an overspend reads as 100%, with the exceeded
// amount shown in TTD on the sub-label (overBudget / overage). A net-negative
// utilisation stays signed (and is treated neutrally).
const budgetUtilization = computed(() => {
  if (!totalBudget.value) return 0
  return Math.min(100, Math.round((totalExpenditure.value / totalBudget.value) * 100))
})
const utilizationBarWidth = computed(() => Math.max(0, budgetUtilization.value))

const utilizationColor = computed(() => {
  if (budgetUtilization.value < 0) return '#64748b'                       // neutral — net negative
  if (overBudget.value || budgetUtilization.value >= 90) return '#ef4444'
  if (budgetUtilization.value >= 75) return '#f59e0b'
  return '#10b981'
})

// Budget Usage needs both a numerator (expenditure) and a denominator (budget).
const usageAvailable = computed(() => props.budgetAvailable && props.expenditureAvailable)
const usageSubLabel = computed(() => {
  if (!props.hasAccess) return 'Department access is not configured'
  if (!props.budgetAvailable) return 'Awaiting budget data'
  if (!props.expenditureAvailable) return 'Awaiting expenditure data'
  // A future FY has a budget but no elapsed months, so every branch below
  // would pass and report the whole allocation as "remaining" — beside two
  // charts that correctly say the year has not started.
  if (!props.expenditureWindowStarted) return 'Fiscal year has not started'
  if (totalExpenditure.value < 0) return 'Net credits exceed expenditure'
  if (overBudget.value) return 'TTD ' + formatAmount(overage.value) + ' over budget'
  return 'TTD ' + formatAmount(variance.value) + ' remaining'
})

// ── Per-chart empty / not-started states ───────────────────────────────────────
const expenditureChartState = (hasData) => {
  if (!props.hasAccess) return { empty: true, msg: 'Department access is not configured' }
  if (!props.expenditureWindowStarted) return { empty: true, msg: 'Fiscal year has not started' }
  if (!props.expenditureAvailable) return { empty: true, msg: 'Expenditure data unavailable' }
  if (!hasData) return { empty: true, msg: 'No expenditure recorded yet' }
  return { empty: false, msg: '' }
}

const monthlyState = computed(() => expenditureChartState((props.monthlyExpenditure?.labels?.length ?? 0) > 0))
const categoryState = computed(() => expenditureChartState((props.expenditureByCategory?.labels?.length ?? 0) > 0))
const burnupState = computed(() => {
  if (!props.hasAccess) return { empty: true, msg: 'Department access is not configured' }
  if (!props.expenditureWindowStarted) return { empty: true, msg: 'Fiscal year has not started' }
  if (!(props.budgetVsActual?.datasets?.length)) return { empty: true, msg: 'No data available' }
  return { empty: false, msg: '' }
})

const chartTextColor = computed(() => isDark.value ? '#cbd5e1' : '#475569')
const chartMutedTextColor = computed(() => isDark.value ? '#94a3b8' : '#64748b')
const chartGridColor = computed(() => isDark.value ? 'rgba(148, 163, 184, 0.16)' : 'rgba(100, 116, 139, 0.14)')

// ── Chart 1: Monthly Expenditure (Bar) ────────────────────────────────────────
const barData = computed(() => ({
  labels: props.monthlyExpenditure?.labels ?? [],
  datasets: [
    {
      label: 'Expenditure',
      data: props.monthlyExpenditure?.datasets?.[0]?.data ?? [],
      backgroundColor: 'rgba(217, 119, 6, 0.75)',
      borderColor: 'rgba(245, 158, 11, 1)',
      borderWidth: 1,
      borderRadius: 5,
      borderSkipped: false,
    },
  ],
}))

const barOptions = computed(() => ({
  responsive: true,
  maintainAspectRatio: false,
  plugins: {
    legend: { display: false },
    tooltip: { callbacks: { label: (ctx) => ' ' + formatCurrency(ctx.parsed.y) } },
  },
  scales: {
    y: {
      ticks: {
        callback: (value) => 'TTD ' + Number(value).toLocaleString(),
        font: { size: 11 },
        color: chartMutedTextColor.value,
      },
      grid: { color: chartGridColor.value },
    },
    x: {
      grid: { display: false },
      ticks: { font: { size: 11 }, color: chartMutedTextColor.value },
    },
  },
}))

// ── Chart 2: Budget Burn-up (Line) ─────────────────────────────────────────────
// Built generically from the controller's datasets so an omitted budget line
// (source down) leaves only the Actual line — no index-based assumptions.
const lineStyles = {
  'Annual Budget': {
    borderColor: 'rgba(100, 116, 139, 0.8)',
    backgroundColor: 'rgba(100, 116, 139, 0.06)',
    borderWidth: 2,
    borderDash: [5, 4],
    pointRadius: 3,
    pointBackgroundColor: 'rgba(100, 116, 139, 0.8)',
    tension: 0.35,
    fill: false,
  },
  'Actual (cumulative)': {
    borderColor: 'rgba(20, 184, 166, 1)',
    backgroundColor: 'rgba(20, 184, 166, 0.08)',
    borderWidth: 2.5,
    pointRadius: 3.5,
    pointBackgroundColor: 'rgba(20, 184, 166, 1)',
    tension: 0.35,
    fill: true,
    spanGaps: false,   // null future points → line ends at the current month
  },
}

const lineData = computed(() => ({
  labels: props.budgetVsActual?.labels ?? [],
  datasets: (props.budgetVsActual?.datasets ?? []).map((ds) => ({
    label: ds.label,
    data: ds.data,
    ...(lineStyles[ds.label] ?? {}),
  })),
}))

const lineOptions = computed(() => ({
  responsive: true,
  maintainAspectRatio: false,
  plugins: {
    legend: {
      display: true,
      position: 'top',
      labels: {
        usePointStyle: true,
        pointStyleWidth: 8,
        padding: 14,
        font: { size: 11 },
        color: chartTextColor.value,
      },
    },
    tooltip: {
      callbacks: {
        label: (ctx) => (ctx.parsed.y == null ? '' : ' ' + formatCurrency(ctx.parsed.y)),
      },
    },
  },
  scales: {
    y: {
      ticks: {
        callback: (value) => 'TTD ' + Number(value).toLocaleString(),
        font: { size: 11 },
        color: chartMutedTextColor.value,
      },
      grid: { color: chartGridColor.value },
    },
    x: {
      grid: { display: false },
      ticks: { font: { size: 11 }, color: chartMutedTextColor.value },
    },
  },
}))

// ── Chart 3: Net Categories (horizontal Bar) ───────────────────────────────────
const categoryPalette = [
  'rgba(245, 158, 11,  0.85)',
  'rgba(20,  184, 166, 0.85)',
  'rgba(59,  130, 246, 0.85)',
  'rgba(168, 85,  247, 0.85)',
  'rgba(239, 68,  68,  0.85)',
  'rgba(16,  185, 129, 0.85)',
  'rgba(236, 72,  153, 0.85)',
  'rgba(249, 115, 22,  0.85)',
  'rgba(100, 116, 139, 0.85)',
]

const categoryBarData = computed(() => {
  const labels = props.expenditureByCategory?.labels ?? []
  return {
    labels,
    datasets: [
      {
        label: 'Net (TTD)',
        data: props.expenditureByCategory?.data ?? [],
        backgroundColor: labels.map((_, i) => categoryPalette[i % categoryPalette.length]),
        borderColor: labels.map((_, i) => categoryPalette[i % categoryPalette.length].replace('0.85', '1')),
        borderWidth: 1,
        borderRadius: 4,
        borderSkipped: false,
      },
    ],
  }
})

const categoryBarOptions = computed(() => ({
  indexAxis: 'y',
  responsive: true,
  maintainAspectRatio: false,
  plugins: {
    legend: { display: false },
    // Tooltip title uses the full (untruncated) label.
    tooltip: { callbacks: { label: (ctx) => ' ' + formatCurrency(ctx.parsed.x) } },
  },
  scales: {
    x: {
      ticks: {
        callback: (value) => 'TTD ' + Number(value).toLocaleString(),
        font: { size: 11 },
        color: chartMutedTextColor.value,
      },
      grid: { color: chartGridColor.value },
    },
    y: {
      ticks: {
        autoSkip: false,
        font: { size: 11 },
        color: chartMutedTextColor.value,
        // Truncate long MainGroup names; the full name stays in the tooltip.
        callback: function (value) {
          const label = this.getLabelForValue(value)
          return label.length > 24 ? label.slice(0, 23) + '…' : label
        },
      },
      grid: { display: false },
    },
  },
}))
</script>

<template>
  <Head title="Dashboard" />

  <div class="space-y-5">

    <!-- Welcome header -->
    <div class="rounded-2xl overflow-hidden border border-white/60 bg-gradient-to-br from-cyan-50 via-white to-slate-100 shadow-xl shadow-slate-950/10 dark:border-white/10 dark:from-[#07111f] dark:via-[#0e2638] dark:to-[#07111f]">
      <div class="relative px-7 py-6 overflow-hidden">
        <div class="absolute inset-0 opacity-[0.18] dark:hidden" style="background-image: radial-gradient(circle at 1px 1px, rgba(8,47,73,0.45) 1px, transparent 0); background-size: 22px 22px;"></div>
        <div class="absolute inset-0 hidden opacity-[0.09] dark:block" style="background-image: radial-gradient(circle at 1px 1px, rgba(255,255,255,0.5) 1px, transparent 0); background-size: 22px 22px;"></div>
        <div class="absolute -right-12 -top-20 h-44 w-44 rounded-full bg-cyan-300/20 blur-3xl"></div>
        <div class="absolute -left-10 bottom-0 h-28 w-28 rounded-full bg-amber-300/20 blur-2xl"></div>
        <div class="absolute top-0 left-0 right-0 h-0.5" style="background: linear-gradient(90deg, #0891b2, #d97706 45%, transparent 100%);"></div>
        <div class="relative">
          <p class="mb-2 text-[11px] font-semibold uppercase tracking-[0.28em] text-cyan-800 dark:text-cyan-100/80">Finance command center</p>
          <h2 class="font-display text-2xl font-bold text-slate-950 dark:text-white">
            Welcome back, <span class="text-amber-700 dark:text-amber-300">{{ userName }}</span>
          </h2>
          <p class="mt-1 text-sm text-slate-600 dark:text-cyan-50/75">
            Finance Management - {{ today }}
          </p>
        </div>
      </div>
    </div>

    <FiscalYearHero
      :active-fiscal-year="activeFiscalYear"
      :current-fiscal-year="currentFiscalYear"
      :years="years"
      :fy-nav="fyNav"
      @select="goToFy"
    />

    <!-- This page has no Filters bar, so the action sits under the year rail.
         Row count is a fixed 12 — the export is always a whole fiscal year. -->
    <div class="flex justify-end">
      <ExportCsvButton
        :href="exportUrl"
        :row-count="12"
        :busy="loading"
        :has-access="hasAccess && expenditureAvailable && expenditureWindowStarted"
        label="Export monthly performance"
      />
    </div>

    <NoAccessNotice v-if="!hasAccess" />

    <!-- Everything below is fiscal-year scoped, so the loading veil covers the
         KPI cards as well as the charts. Veiling only the charts would leave
         stale TTD totals legible while the new year loads. -->
    <div class="relative space-y-5">
      <LedgerLoadingOverlay :show="loading" label="Loading dashboard" />

      <!-- KPI cards -->
      <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">

        <!-- Total Budget -->
        <div class="bg-surface rounded-xl border border-line p-5 relative overflow-hidden shadow-sm">
          <div class="absolute top-0 left-0 bottom-0 w-1 rounded-l-xl" style="background: #14b8a6;"></div>
          <div class="pl-1">
            <div class="flex items-start justify-between mb-3">
              <div>
                <p class="text-xs font-semibold text-tx-muted uppercase tracking-wider">Total Budget</p>
                <!-- Goods and services only — vw_BudgetAllocation is scoped to the 41
                     reporting-line accounts, so payroll is excluded from this figure. -->
                <p class="text-[10px] text-tx-subtle mt-0.5">Approved allocation, goods and services</p>
              </div>
              <div class="w-9 h-9 rounded-lg flex items-center justify-center flex-shrink-0" style="background: rgba(20,184,166,0.1);">
                <i class="fas fa-chart-pie text-sm" style="color: #0d9488;"></i>
              </div>
            </div>
            <!-- Narrowest condition first. This card is not currently reachable
                 with hasAccess false and budgetAvailable true — budgetTotal()
                 reports unavailable on the empty-years path — but the ordering
                 must not depend on that, or a change there turns this into the
                 fake zero the expenditure card had. -->
            <template v-if="!hasAccess">
              <p class="font-display text-base font-semibold text-tx-muted leading-tight mt-2">Not assigned</p>
              <p class="text-[10px] text-tx-subtle mt-1">Department access is not configured.</p>
            </template>
            <template v-else-if="!budgetAvailable">
              <p class="font-display text-base font-semibold text-tx-muted leading-tight mt-2">Budget data unavailable</p>
              <p class="text-[10px] text-tx-subtle mt-1">No budget allocation could be loaded for this fiscal year.</p>
            </template>
            <template v-else>
              <p class="text-xs font-semibold text-tx-muted mb-0.5">TTD</p>
              <p class="font-display text-2xl font-bold text-tx-primary leading-none">{{ formatAmount(totalBudget) }}</p>
            </template>
          </div>
        </div>

        <!-- Budget Utilization -->
        <div class="bg-surface rounded-xl border border-line p-5 relative overflow-hidden shadow-sm">
          <div class="absolute top-0 left-0 bottom-0 w-1 rounded-l-xl" :style="{ background: utilizationColor }"></div>
          <div class="pl-1">
            <div class="flex items-start justify-between mb-3">
              <div>
                <p class="text-xs font-semibold text-tx-muted uppercase tracking-wider">Budget Usage</p>
                <p class="text-[10px] text-tx-subtle mt-0.5">{{ usageSubLabel }}</p>
              </div>
              <div class="w-9 h-9 rounded-lg flex items-center justify-center flex-shrink-0" :style="{ background: utilizationColor + '18' }">
                <i class="fas fa-gauge-high text-sm" :style="{ color: utilizationColor }"></i>
              </div>
            </div>
            <template v-if="usageAvailable">
              <p class="font-display text-2xl font-bold leading-none" :style="{ color: utilizationColor }">{{ budgetUtilization }}%</p>
              <!-- Progress bar -->
              <div class="mt-3 h-1.5 bg-surface-3 rounded-full overflow-hidden">
                <div
                  class="h-full rounded-full transition-all duration-700"
                  :style="{ width: utilizationBarWidth + '%', background: utilizationColor }"
                ></div>
              </div>
            </template>
            <template v-else>
              <p class="font-display text-2xl font-bold leading-none text-tx-muted">&mdash;</p>
            </template>
          </div>
        </div>

        <!-- YTD Expenditure -->
        <div class="bg-surface rounded-xl border border-line p-5 relative overflow-hidden shadow-sm">
          <div class="absolute top-0 left-0 bottom-0 w-1 rounded-l-xl" style="background: #f59e0b;"></div>
          <div class="pl-1">
            <div class="flex items-start justify-between mb-3">
              <div>
                <p class="text-xs font-semibold text-tx-muted uppercase tracking-wider">{{ expenditureCardTitle }}</p>
                <p class="text-[10px] text-tx-subtle mt-0.5">
                  FY {{ fiscalYear }}<template v-if="hasAccess">
                  <span v-if="!expenditureWindowStarted"> &middot; fiscal year has not started</span>
                  <span v-else-if="isPastFy"> &middot; full year</span>
                  <span v-else-if="latestPeriodLabel"> &middot; through {{ latestPeriodLabel }}</span>
                  </template>
                </p>
              </div>
              <div class="w-9 h-9 rounded-lg flex items-center justify-center flex-shrink-0" style="background: rgba(245,158,11,0.1);">
                <i class="fas fa-coins text-sm" style="color: #d97706;"></i>
              </div>
            </div>
            <!-- Ordered narrowest-first, and the order is load-bearing. This
                 query does not FAIL for a user with no department: the access
                 view is joined live, so it succeeds and returns no rows, leaving
                 expenditureAvailable true. Testing that first (as this card used
                 to) made the branches below unreachable and printed a fabricated
                 TTD 0.00 to every unmapped user. The same applies to a fiscal
                 year that has not begun.
                 hasAccess is safe to test first because the controller forces it
                 true when the probe itself fails — so it can only be false when
                 the probe succeeded and said no, never during an outage. -->
            <template v-if="!hasAccess">
              <p class="font-display text-base font-semibold text-tx-muted leading-tight mt-2">Not assigned</p>
              <p class="text-[10px] text-tx-subtle mt-1">Department access is not configured.</p>
            </template>
            <template v-else-if="!expenditureAvailable">
              <p class="font-display text-base font-semibold text-tx-muted leading-tight mt-2">Expenditure unavailable</p>
              <p class="text-[10px] text-tx-subtle mt-1">Financial data source could not be reached.</p>
            </template>
            <template v-else-if="!expenditureWindowStarted">
              <p class="font-display text-base font-semibold text-tx-muted leading-tight mt-2">Not started</p>
              <p class="text-[10px] text-tx-subtle mt-1">This fiscal year has not begun.</p>
            </template>
            <template v-else>
              <p class="text-xs font-semibold text-tx-muted mb-0.5">TTD</p>
              <p class="font-display text-2xl font-bold text-tx-primary leading-none">{{ formatAmount(totalExpenditure) }}</p>
            </template>
          </div>
        </div>

      </div>

      <!-- Chart grid -->
      <div class="grid grid-cols-1 lg:grid-cols-2 xl:grid-cols-3 gap-5">

        <!-- Card 1: Budget Burn-up -->
        <div class="bg-surface rounded-xl shadow-sm border border-line p-5 flex flex-col">
          <div class="mb-4 flex items-start justify-between">
            <div>
              <h3 class="text-sm font-bold text-tx-primary">Cumulative Spend vs Budget</h3>
              <p class="text-xs text-tx-muted mt-0.5">Cumulative actual vs annual allocation (TTD)</p>
            </div>
            <div class="w-8 h-8 rounded-lg flex items-center justify-center" style="background: rgba(20,184,166,0.1);">
              <i class="fas fa-chart-line text-xs" style="color: #0d9488;"></i>
            </div>
          </div>
          <div class="flex-1 min-h-[220px]">
            <Line v-if="!burnupState.empty" :data="lineData" :options="lineOptions" />
            <div v-else class="h-full flex items-center justify-center text-xs text-tx-subtle">{{ burnupState.msg }}</div>
          </div>
        </div>

        <!-- Card 2: Net Categories -->
        <div class="bg-surface rounded-xl shadow-sm border border-line p-5 flex flex-col">
          <div class="mb-4 flex items-start justify-between">
            <div>
              <h3 class="text-sm font-bold text-tx-primary">Net Categories</h3>
              <p class="text-xs text-tx-muted mt-0.5">Top material categories + Other &middot; net of corrections (TTD)</p>
            </div>
            <div class="w-8 h-8 rounded-lg flex items-center justify-center" style="background: rgba(168,85,247,0.1);">
              <i class="fas fa-chart-bar text-xs" style="color: #9333ea;"></i>
            </div>
          </div>
          <div class="flex-1 min-h-[300px]">
            <Bar v-if="!categoryState.empty" :data="categoryBarData" :options="categoryBarOptions" />
            <div v-else class="h-full flex items-center justify-center text-xs text-tx-subtle">{{ categoryState.msg }}</div>
          </div>
        </div>

        <!-- Card 3: Monthly Expenditure -->
        <div class="bg-surface rounded-xl shadow-sm border border-line p-5 flex flex-col lg:col-span-2 xl:col-span-1">
          <div class="mb-4 flex items-start justify-between">
            <div>
              <h3 class="text-sm font-bold text-tx-primary">Monthly Expenditure</h3>
              <p class="text-xs text-tx-muted mt-0.5">Spend by month (TTD)</p>
            </div>
            <div class="w-8 h-8 rounded-lg flex items-center justify-center" style="background: rgba(245,158,11,0.1);">
              <i class="fas fa-chart-bar text-xs" style="color: #d97706;"></i>
            </div>
          </div>
          <div class="flex-1 min-h-[220px]">
            <Bar v-if="!monthlyState.empty" :data="barData" :options="barOptions" />
            <div v-else class="h-full flex items-center justify-center text-xs text-tx-subtle">{{ monthlyState.msg }}</div>
          </div>
        </div>

      </div>
    </div><!-- /loading region -->
  </div>
</template>
