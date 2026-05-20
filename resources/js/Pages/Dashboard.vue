<script setup>
import { computed } from 'vue'
import { Head } from '@inertiajs/vue3'
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

const props = defineProps({
  userName: String,
  monthlyExpenditure: Object,
  budgetVsActual: Object,
  expenditureByCategory: Object,
})

// ── Format currency for tooltips ──────────────────────────────────────────────
const formatCurrency = (value) =>
  'TTD ' + Number(value ?? 0).toLocaleString('en-TT', { minimumFractionDigits: 2, maximumFractionDigits: 2 })

// ── Today's date ──────────────────────────────────────────────────────────────
const today = new Date().toLocaleDateString('en-TT', { year: 'numeric', month: 'long', day: 'numeric' })

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
      backgroundColor: 'rgba(99, 102, 241, 0.75)',
      borderColor: 'rgba(99, 102, 241, 1)',
      borderWidth: 1,
      borderRadius: 6,
      borderSkipped: false,
    },
  ],
}))

const barOptions = {
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
      },
      grid: { color: 'rgba(156, 163, 175, 0.15)' },
    },
    x: {
      grid: { display: false },
    },
  },
}

// ── Chart 2: Budget vs Actual (Line) ─────────────────────────────────────────
const lineData = computed(() => ({
  labels: props.budgetVsActual?.labels ?? [],
  datasets: [
    {
      label: 'Budget',
      data: props.budgetVsActual?.datasets?.[0]?.data ?? [],
      borderColor: 'rgba(100, 116, 139, 0.9)',
      backgroundColor: 'rgba(100, 116, 139, 0.08)',
      borderWidth: 2,
      borderDash: [6, 3],
      pointRadius: 4,
      pointBackgroundColor: 'rgba(100, 116, 139, 0.9)',
      tension: 0.35,
      fill: false,
    },
    {
      label: 'Actual',
      data: props.budgetVsActual?.datasets?.[1]?.data ?? [],
      borderColor: 'rgba(99, 102, 241, 1)',
      backgroundColor: 'rgba(99, 102, 241, 0.08)',
      borderWidth: 2.5,
      pointRadius: 4,
      pointBackgroundColor: 'rgba(99, 102, 241, 1)',
      tension: 0.35,
      fill: false,
    },
  ],
}))

const lineOptions = {
  responsive: true,
  maintainAspectRatio: false,
  plugins: {
    legend: {
      display: true,
      position: 'top',
      labels: { usePointStyle: true, pointStyleWidth: 10, padding: 16 },
    },
    tooltip: currencyTooltip,
  },
  scales: {
    y: {
      ticks: {
        callback: (value) => 'TTD ' + Number(value).toLocaleString(),
      },
      grid: { color: 'rgba(156, 163, 175, 0.15)' },
    },
    x: {
      grid: { display: false },
    },
  },
}

// ── Chart 3: Expenditure by Category (Doughnut) ───────────────────────────────
const doughnutPalette = [
  'rgba(99,  102, 241, 0.85)',
  'rgba(168,  85, 247, 0.85)',
  'rgba( 59, 130, 246, 0.85)',
  'rgba( 20, 184, 166, 0.85)',
  'rgba(245, 158,  11, 0.85)',
  'rgba(239,  68,  68, 0.85)',
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

const doughnutOptions = {
  responsive: true,
  maintainAspectRatio: false,
  cutout: '62%',
  plugins: {
    legend: {
      display: true,
      position: 'bottom',
      labels: { usePointStyle: true, pointStyleWidth: 10, padding: 14, font: { size: 12 } },
    },
    tooltip: {
      callbacks: {
        label: (ctx) => ' ' + formatCurrency(ctx.parsed),
      },
    },
  },
}
</script>

<template>
  <Head title="Dashboard" />

  <div class="space-y-6">

    <!-- Welcome header -->
    <div class="bg-surface rounded-xl shadow-sm border border-line overflow-hidden">
      <div class="bg-gradient-to-r from-blue-600 via-indigo-600 to-purple-600 px-6 py-7">
        <h2 class="text-2xl font-bold text-white tracking-tight">
          Welcome back, <span class="text-indigo-200">{{ userName }}</span>
        </h2>
        <p class="mt-1 text-sm text-indigo-200">Finance Management &mdash; {{ today }}</p>
      </div>
    </div>

    <!-- Chart grid -->
    <div class="grid grid-cols-1 lg:grid-cols-2 xl:grid-cols-3 gap-6">

      <!-- Card 1: Monthly Expenditure -->
      <div class="bg-surface rounded-xl shadow-sm border border-line p-5 flex flex-col">
        <div class="mb-4">
          <h3 class="text-base font-semibold text-tx-primary">Monthly Expenditure</h3>
          <p class="text-xs text-tx-muted mt-0.5">Spend by month</p>
        </div>
        <div class="flex-1 min-h-[220px]">
          <Bar :data="barData" :options="barOptions" />
        </div>
      </div>

      <!-- Card 2: Budget vs Actual -->
      <div class="bg-surface rounded-xl shadow-sm border border-line p-5 flex flex-col">
        <div class="mb-4">
          <h3 class="text-base font-semibold text-tx-primary">Budget vs Actual Spend</h3>
          <p class="text-xs text-tx-muted mt-0.5">Planned versus realised expenditure</p>
        </div>
        <div class="flex-1 min-h-[220px]">
          <Line :data="lineData" :options="lineOptions" />
        </div>
      </div>

      <!-- Card 3: Expenditure by Category -->
      <div class="bg-surface rounded-xl shadow-sm border border-line p-5 flex flex-col lg:col-span-2 xl:col-span-1">
        <div class="mb-4">
          <h3 class="text-base font-semibold text-tx-primary">Expenditure by Category</h3>
          <p class="text-xs text-tx-muted mt-0.5">Category breakdown</p>
        </div>
        <div class="flex-1 min-h-[240px] flex items-center justify-center">
          <Doughnut :data="doughnutData" :options="doughnutOptions" />
        </div>
      </div>

    </div>
  </div>
</template>
