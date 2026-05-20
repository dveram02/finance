<script setup>
import { computed } from 'vue'
import { Head } from '@inertiajs/vue3'
import { useDarkMode } from '@/composables/useDarkMode'
import {
  Chart as ChartJS,
  Title,
  Tooltip,
  Legend,
  BarElement,
  LineElement,
  PointElement,
  ArcElement,
  CategoryScale,
  LinearScale,
  Filler,
} from 'chart.js'
import { Bar, Line, Doughnut } from 'vue-chartjs'

ChartJS.register(
  Title,
  Tooltip,
  Legend,
  BarElement,
  LineElement,
  PointElement,
  ArcElement,
  CategoryScale,
  LinearScale,
  Filler,
)

const { isDark } = useDarkMode()

const props = defineProps({
  userName: String,
  monthlyExpenditure: Object,
  budgetVsActual: Object,
  expenditureByCategory: Object,
})

// ── Currency helpers ──────────────────────────────────────────────────────────
const formatCurrency = (value) =>
  'TTD ' + Number(value ?? 0).toLocaleString('en-TT', { minimumFractionDigits: 2, maximumFractionDigits: 2 })

const formatAmount = (value) =>
  Number(value ?? 0).toLocaleString('en-TT', { minimumFractionDigits: 2, maximumFractionDigits: 2 })

// ── Today's date ──────────────────────────────────────────────────────────────
const today = new Date().toLocaleDateString('en-TT', { year: 'numeric', month: 'long', day: 'numeric' })
const currentYear = new Date().getFullYear()

// ── KPI computations ──────────────────────────────────────────────────────────
const totalExpenditure = computed(() => {
  const data = props.monthlyExpenditure?.datasets?.[0]?.data ?? []
  return data.reduce((sum, v) => sum + (v ?? 0), 0)
})

const totalBudget = computed(() => {
  const data = props.budgetVsActual?.datasets?.[0]?.data ?? []
  return data.reduce((sum, v) => sum + (v ?? 0), 0)
})

const variance = computed(() => totalBudget.value - totalExpenditure.value)

const budgetUtilization = computed(() => {
  if (!totalBudget.value) return 0
  return Math.min(100, Math.round((totalExpenditure.value / totalBudget.value) * 100))
})

const utilizationColor = computed(() => {
  if (budgetUtilization.value >= 90) return '#ef4444'
  if (budgetUtilization.value >= 75) return '#f59e0b'
  return '#10b981'
})

const chartTextColor = computed(() => isDark.value ? '#cbd5e1' : '#475569')
const chartMutedTextColor = computed(() => isDark.value ? '#94a3b8' : '#64748b')
const chartGridColor = computed(() => isDark.value ? 'rgba(148, 163, 184, 0.16)' : 'rgba(100, 116, 139, 0.14)')

// ── Shared tooltip callback ───────────────────────────────────────────────────
const currencyTooltip = {
  callbacks: {
    label: (ctx) => ' ' + formatCurrency(ctx.parsed.y ?? ctx.parsed),
  },
}

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
    tooltip: currencyTooltip,
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

// ── Chart 2: Budget vs Actual (Line) ─────────────────────────────────────────
const lineData = computed(() => ({
  labels: props.budgetVsActual?.labels ?? [],
  datasets: [
    {
      label: 'Budget',
      data: props.budgetVsActual?.datasets?.[0]?.data ?? [],
      borderColor: 'rgba(100, 116, 139, 0.8)',
      backgroundColor: 'rgba(100, 116, 139, 0.06)',
      borderWidth: 2,
      borderDash: [5, 4],
      pointRadius: 3,
      pointBackgroundColor: 'rgba(100, 116, 139, 0.8)',
      tension: 0.35,
      fill: false,
    },
    {
      label: 'Actual',
      data: props.budgetVsActual?.datasets?.[1]?.data ?? [],
      borderColor: 'rgba(20, 184, 166, 1)',
      backgroundColor: 'rgba(20, 184, 166, 0.08)',
      borderWidth: 2.5,
      pointRadius: 3.5,
      pointBackgroundColor: 'rgba(20, 184, 166, 1)',
      tension: 0.35,
      fill: true,
    },
  ],
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
    tooltip: currencyTooltip,
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

// ── Chart 3: Expenditure by Category (Doughnut) ───────────────────────────────
const doughnutPalette = [
  'rgba(245, 158, 11,  0.85)',
  'rgba(20,  184, 166, 0.85)',
  'rgba(59,  130, 246, 0.85)',
  'rgba(168, 85,  247, 0.85)',
  'rgba(239, 68,  68,  0.85)',
  'rgba(16,  185, 129, 0.85)',
]

const doughnutData = computed(() => ({
  labels: props.expenditureByCategory?.labels ?? [],
  datasets: [
    {
      data: props.expenditureByCategory?.data ?? [],
      backgroundColor: doughnutPalette,
      borderColor: doughnutPalette.map(c => c.replace('0.85', '1')),
      borderWidth: 2,
      hoverOffset: 8,
    },
  ],
}))

const doughnutOptions = computed(() => ({
  responsive: true,
  maintainAspectRatio: false,
  cutout: '64%',
  plugins: {
    legend: {
      display: true,
      position: 'bottom',
      labels: {
        usePointStyle: true,
        pointStyleWidth: 8,
        padding: 12,
        font: { size: 11 },
        color: chartTextColor.value,
      },
    },
    tooltip: {
      callbacks: {
        label: (ctx) => ' ' + formatCurrency(ctx.parsed),
      },
    },
  },
}))
</script>

<template>
  <Head title="Dashboard" />

  <div class="space-y-5">

    <!-- Welcome header -->
    <div
      class="rounded-xl overflow-hidden border border-line shadow-sm"
      :style="isDark
        ? 'background: linear-gradient(135deg, #0b1625 0%, #0e2040 50%, #0b1625 100%);'
        : 'background: linear-gradient(135deg, #1d4ed8 0%, #4338ca 60%, #6d28d9 100%);'"
    >
      <div class="relative px-7 py-6 overflow-hidden">
        <!-- Subtle pattern overlay -->
        <div class="absolute inset-0 opacity-5" style="background-image: radial-gradient(circle at 1px 1px, rgba(255,255,255,0.4) 1px, transparent 0); background-size: 24px 24px;"></div>
        <!-- Gold accent top bar -->
        <div class="absolute top-0 left-0 right-0 h-0.5" style="background: linear-gradient(90deg, #d97706, #f59e0b 40%, transparent 100%);"></div>
        <div class="relative">
          <h2 class="font-display text-2xl font-bold text-white">
            Welcome back, <span class="text-amber-300">{{ userName }}</span>
          </h2>
          <p class="mt-1 text-sm text-blue-100/70">
            Finance Management &mdash; {{ today }}
          </p>
        </div>
      </div>
    </div>

    <!-- KPI cards -->
    <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">

      <!-- YTD Expenditure -->
      <div class="bg-surface rounded-xl border border-line p-5 relative overflow-hidden shadow-sm">
        <div class="absolute top-0 left-0 bottom-0 w-1 rounded-l-xl" style="background: #f59e0b;"></div>
        <div class="pl-1">
          <div class="flex items-start justify-between mb-3">
            <div>
              <p class="text-xs font-semibold text-tx-muted uppercase tracking-wider">YTD Expenditure</p>
              <p class="text-[10px] text-tx-subtle mt-0.5">{{ currentYear }} fiscal year</p>
            </div>
            <div class="w-9 h-9 rounded-lg flex items-center justify-center flex-shrink-0" style="background: rgba(245,158,11,0.1);">
              <i class="fas fa-coins text-sm" style="color: #d97706;"></i>
            </div>
          </div>
          <p class="text-xs font-semibold text-tx-muted mb-0.5">TTD</p>
          <p class="font-display text-2xl font-bold text-tx-primary leading-none">{{ formatAmount(totalExpenditure) }}</p>
        </div>
      </div>

      <!-- Total Budget -->
      <div class="bg-surface rounded-xl border border-line p-5 relative overflow-hidden shadow-sm">
        <div class="absolute top-0 left-0 bottom-0 w-1 rounded-l-xl" style="background: #14b8a6;"></div>
        <div class="pl-1">
          <div class="flex items-start justify-between mb-3">
            <div>
              <p class="text-xs font-semibold text-tx-muted uppercase tracking-wider">Total Budget</p>
              <p class="text-[10px] text-tx-subtle mt-0.5">Approved allocation</p>
            </div>
            <div class="w-9 h-9 rounded-lg flex items-center justify-center flex-shrink-0" style="background: rgba(20,184,166,0.1);">
              <i class="fas fa-chart-pie text-sm" style="color: #0d9488;"></i>
            </div>
          </div>
          <p class="text-xs font-semibold text-tx-muted mb-0.5">TTD</p>
          <p class="font-display text-2xl font-bold text-tx-primary leading-none">{{ formatAmount(totalBudget) }}</p>
        </div>
      </div>

      <!-- Budget Utilization -->
      <div class="bg-surface rounded-xl border border-line p-5 relative overflow-hidden shadow-sm">
        <div class="absolute top-0 left-0 bottom-0 w-1 rounded-l-xl" :style="{ background: utilizationColor }"></div>
        <div class="pl-1">
          <div class="flex items-start justify-between mb-3">
            <div>
              <p class="text-xs font-semibold text-tx-muted uppercase tracking-wider">Budget Usage</p>
              <p class="text-[10px] text-tx-subtle mt-0.5">
                {{ variance >= 0 ? 'TTD ' + formatAmount(variance) + ' remaining' : 'Over budget' }}
              </p>
            </div>
            <div class="w-9 h-9 rounded-lg flex items-center justify-center flex-shrink-0" :style="{ background: utilizationColor + '18' }">
              <i class="fas fa-gauge-high text-sm" :style="{ color: utilizationColor }"></i>
            </div>
          </div>
          <p class="font-display text-2xl font-bold leading-none" :style="{ color: utilizationColor }">{{ budgetUtilization }}%</p>
          <!-- Progress bar -->
          <div class="mt-3 h-1.5 bg-surface-3 rounded-full overflow-hidden">
            <div
              class="h-full rounded-full transition-all duration-700"
              :style="{ width: budgetUtilization + '%', background: utilizationColor }"
            ></div>
          </div>
        </div>
      </div>

    </div>

    <!-- Chart grid -->
    <div class="grid grid-cols-1 lg:grid-cols-2 xl:grid-cols-3 gap-5">

      <!-- Card 1: Monthly Expenditure -->
      <div class="bg-surface rounded-xl shadow-sm border border-line p-5 flex flex-col">
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
          <Bar :data="barData" :options="barOptions" />
        </div>
      </div>

      <!-- Card 2: Budget vs Actual -->
      <div class="bg-surface rounded-xl shadow-sm border border-line p-5 flex flex-col">
        <div class="mb-4 flex items-start justify-between">
          <div>
            <h3 class="text-sm font-bold text-tx-primary">Budget vs Actual</h3>
            <p class="text-xs text-tx-muted mt-0.5">Planned vs realised (TTD)</p>
          </div>
          <div class="w-8 h-8 rounded-lg flex items-center justify-center" style="background: rgba(20,184,166,0.1);">
            <i class="fas fa-chart-line text-xs" style="color: #0d9488;"></i>
          </div>
        </div>
        <div class="flex-1 min-h-[220px]">
          <Line :data="lineData" :options="lineOptions" />
        </div>
      </div>

      <!-- Card 3: Expenditure by Category -->
      <div class="bg-surface rounded-xl shadow-sm border border-line p-5 flex flex-col lg:col-span-2 xl:col-span-1">
        <div class="mb-4 flex items-start justify-between">
          <div>
            <h3 class="text-sm font-bold text-tx-primary">Expenditure by Category</h3>
            <p class="text-xs text-tx-muted mt-0.5">Category breakdown (TTD)</p>
          </div>
          <div class="w-8 h-8 rounded-lg flex items-center justify-center" style="background: rgba(168,85,247,0.1);">
            <i class="fas fa-chart-pie text-xs" style="color: #9333ea;"></i>
          </div>
        </div>
        <div class="flex-1 min-h-[240px] flex items-center justify-center">
          <Doughnut :data="doughnutData" :options="doughnutOptions" />
        </div>
      </div>

    </div>
  </div>
</template>
