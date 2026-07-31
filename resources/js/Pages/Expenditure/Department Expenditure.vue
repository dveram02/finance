<script setup>
import { ref, computed, watch, onMounted, onUnmounted, nextTick } from 'vue'
import { Head, Link, router } from '@inertiajs/vue3'

const props = defineProps({
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
    isScaffold:        Boolean,
})

// ── Filter state (categorical only — FY is steered by the hero navigator) ───────
const filters = ref({
    cluster:        props.filters.cluster        ?? '',
    institution:    props.filters.institution    ?? '',
    responsibility: props.filters.responsibility ?? '',
    department:     props.filters.department     ?? '',
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
    ['cluster', 'institution', 'responsibility', 'department']
        .filter(k => filters.value[k] !== '' && filters.value[k] != null).length
)

// ── Navigation helpers ──────────────────────────────────────────────────────────
const applyFilters = () => {
    const params = Object.fromEntries(
        Object.entries(filters.value).filter(([, v]) => v !== '' && v !== null)
    )
    router.get(route('department-expenditure.index'), params, {
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
        department: '', fy: filters.value.fy,
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

// ── Scroll affordance ───────────────────────────────────────────────────────────
// Whether the table can scroll depends on viewport width, the sidebar, and how
// wide the identity columns have grown at the current breakpoint — none of which
// can be decided up front, so measure the element.
const scroller = ref(null)
const canScroll = ref(false)
let resizeObserver = null

const measureScroll = () => {
    const el = scroller.value
    canScroll.value = !!el && el.scrollWidth - el.clientWidth > 1
}

// Row count changes alter scrollWidth without resizing the container, so the
// observer alone would miss them.
watch(() => props.rows?.data?.length, () => nextTick(measureScroll))

// ── Keyboard navigation (← / →) ─────────────────────────────────────────────────
// The arrow keys mean different things depending on where the user's attention
// is. Over the table they scroll the months, which is what someone reading a row
// wants; anywhere else they step between fiscal years. Without this split, trying
// to scroll to September silently throws you into a different year.
// Tracked as state rather than read from document.activeElement, because that is
// not reactive — the hint below has to re-render when focus moves.
const pointerInTable = ref(false)
const tableFocused = ref(false)

// Scroll by exactly one month column so figures stay aligned under their
// headings, rather than the browser's fixed ~40px nudge. Measured from a real
// cell because the width changes across breakpoints.
const monthStep = () => scroller.value?.querySelector('thead .col-month')?.offsetWidth || 96

const scrollMonths = (direction) => {
    const reduceMotion = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches

    scroller.value?.scrollBy({
        left: direction * monthStep(),
        behavior: reduceMotion ? 'auto' : 'smooth',
    })
}

// True when the arrows would scroll rather than change year — drives the hint.
const arrowsScrollTable = computed(() =>
    canScroll.value && (pointerInTable.value || tableFocused.value)
)

const handleKeydown = (e) => {
    // A focused <select> owns its own arrow-key behaviour; never steal it.
    const tag = document.activeElement?.tagName
    if (tag === 'SELECT' || tag === 'INPUT' || tag === 'TEXTAREA') return

    if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') return

    const direction = e.key === 'ArrowLeft' ? -1 : 1

    // Table wins while the user is in it — but only if there is anything to
    // scroll, so on a wide screen the arrows still step fiscal years.
    if (arrowsScrollTable.value) {
        e.preventDefault()
        scrollMonths(direction)

        return
    }

    const targetYear = direction === -1 ? props.fyNav?.prev : props.fyNav?.next
    if (targetYear != null) {
        e.preventDefault()
        goToFy(targetYear)
    }
}

// ── Loading state (shown while a filter / FY / page reload is in flight) ─────────
const loading = ref(false)
let stopOnStart = null
let stopOnFinish = null

onMounted(() => {
    window.addEventListener('keydown', handleKeydown)
    scrollActiveIntoView()

    measureScroll()
    if (scroller.value) {
        resizeObserver = new ResizeObserver(measureScroll)
        resizeObserver.observe(scroller.value)
    }

    stopOnStart = router.on('start', (event) => {
        const url = event.detail?.visit?.url
        if (!url || String(url.pathname ?? url).includes('department-expenditure')) {
            loading.value = true
        }
    })
    stopOnFinish = router.on('finish', () => {
        loading.value = false
    })
})

onUnmounted(() => {
    window.removeEventListener('keydown', handleKeydown)
    resizeObserver?.disconnect()
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
// that costs width and adds nothing. The symbol stays on the YTD column and the
// KPIs, and the column group is labelled TTD in the header.
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
// the attribute entirely (Vue drops null-bound attributes), so the tooltip
// appears only where line-clamp has something to hide. The thresholds are the
// approximate two-line capacity of each column at its fixed width.
const clampedTitle = (text, maxChars) =>
    text && String(text).length > maxChars ? text : null

const IDENTITY_CLAMP = { institution: 44, department: 44, account: 52 }

// ── Reading aids for a 16-column grid ───────────────────────────────────────────
// Tracing a figure back to its month header across this many columns is the main
// thing that makes wide financial tables tiring to read. Two cheap aids fix most
// of it: a crosshair on the hovered column, and shading that lets the shape of a
// year register without reading any numbers.

// Delegated rather than 300 per-cell listeners.
const hoveredMonth = ref(null)

const onTableHover = (e) => {
    const cell = e.target?.closest?.('[data-month-index]')
    hoveredMonth.value = cell ? Number(cell.dataset.monthIndex) : null
}

// Each row is shaded against its OWN largest month, not a table-wide maximum.
// A global scale would wash out every small account into a uniform pale band and
// answer the wrong question — the useful one is "when did THIS account spend".
const rowPeaks = computed(() =>
    (props.rows?.data ?? []).map((row) =>
        Math.max(...props.months.map((m) => Math.abs(Number(row[m.key]) || 0)), 0)
    )
)

// Returned as a background-IMAGE so it layers over the column-hover
// background-COLOR instead of replacing it — the two aids have to coexist.
const heatStyle = (row, monthKey, rowIndex) => {
    const value = Number(row[monthKey]) || 0
    const peak = rowPeaks.value[rowIndex] || 0
    if (!value || !peak) return null

    const intensity = Math.abs(value) / peak
    const alpha = (0.035 + intensity * 0.125).toFixed(3)
    const rgb = value < 0 ? '220, 38, 38' : '217, 119, 6'

    return { backgroundImage: `linear-gradient(rgba(${rgb}, ${alpha}), rgba(${rgb}, ${alpha}))` }
}


</script>

<template>
    <Head title="Department Expenditure" />

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
            <h1 class="font-display text-3xl font-bold text-tx-primary tracking-tight">Department Expenditure</h1>
            <p class="text-sm text-tx-subtle mt-1">
                Full-year departmental expenditure by account, month by month across the fiscal year.
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

            <!-- Total YTD Expenditure -->
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

            <!-- Highest Spend Month -->
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

            <!-- Accounts Reported -->
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

            <!-- Table caption strip: units + scroll affordance -->
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

            <!-- Loading overlay — financial coin spinner while a visit is in flight -->
            <transition name="overlay">
                <div v-if="loading"
                    class="absolute inset-0 z-40 grid place-items-center bg-surface/70 backdrop-blur-[2px]">
                    <div class="flex flex-col items-center gap-4">
                        <div class="coin" aria-hidden="true">
                            <div class="coin__face coin__front">$</div>
                            <div class="coin__face coin__back">$</div>
                        </div>
                        <p class="text-[11px] font-semibold uppercase tracking-[0.22em] text-tx-subtle">
                            Loading expenditure<span class="loading-dots"></span>
                        </p>
                    </div>
                </div>
            </transition>

            <!-- tabindex makes the region reachable by keyboard, so arrow-key
                 scrolling is available without a mouse. role/aria-label give that
                 focus stop a name instead of announcing as an anonymous group. -->
            <div ref="scroller"
                class="table-scroll overflow-x-auto"
                tabindex="0"
                role="region"
                aria-label="Monthly expenditure table, scrollable horizontally"
                @mouseenter="pointerInTable = true"
                @mouseleave="pointerInTable = false; hoveredMonth = null"
                @focusin="tableFocused = true"
                @focusout="tableFocused = false">
                <table class="ledger-table divide-y divide-line"
                    @mouseover="onTableHover">
                    <!-- Column widths live here, not on the cells. With
                         table-layout: fixed the browser treats these as
                         authoritative, which is what keeps the pinned columns'
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
                            <th class="col-inst px-3 py-3 text-left text-[11px] font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">
                                Institution
                            </th>
                            <th class="col-dept px-3 py-3 text-left text-[11px] font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">
                                Department
                            </th>
                            <th class="col-acct px-3 py-3 text-left text-[11px] font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">
                                Account
                            </th>

                            <th v-for="(m, i) in months" :key="m.key"
                                :data-month-index="i"
                                :class="[
                                    'col-month px-2.5 py-3 text-right text-[11px] font-semibold uppercase tracking-wider whitespace-nowrap',
                                    m.quarterStart ? 'quarter-edge' : '',
                                    hoveredMonth === i ? 'is-col-hover text-amber-700 dark:text-amber-300'
                                        : m.future ? 'text-tx-muted/50' : 'text-tx-subtle',
                                ]">
                                {{ m.label }}
                                <span class="block text-[9px] font-normal tabular-nums opacity-70">'{{ m.year }}</span>
                            </th>

                            <th class="col-ytd px-3 py-3 text-right text-[11px] font-semibold text-tx-subtle uppercase tracking-wider whitespace-nowrap">
                                YTD
                            </th>
                        </tr>
                    </thead>
                    <tbody class="divide-y divide-line">

                        <!-- Empty state -->
                        <tr v-if="rows.data.length === 0">
                            <td :colspan="months.length + 4" class="px-4 py-16 text-center">
                                <div class="inline-grid place-items-center h-14 w-14 rounded-full bg-surface-3 mb-3">
                                    <i class="fas fa-folder-open text-xl text-tx-muted"></i>
                                </div>
                                <p class="text-sm font-medium text-tx-body">No expenditure found</p>
                                <p class="text-xs text-tx-muted mt-1">
                                    Nothing in <span class="font-semibold">FY {{ activeFiscalYear }}</span>
                                    <template v-if="activeFilterCount"> matching your filters</template>.
                                </p>
                            </td>
                        </tr>

                        <!-- Data rows -->
                        <tr v-for="(row, rowIndex) in rows.data" :key="rowIndex"
                            class="group hover:bg-amber-50/40 dark:hover:bg-amber-900/10 transition-colors">

                            <td class="col-inst px-3 py-3 text-sm text-tx-body align-top">
                                <span class="line-clamp-2" :title="clampedTitle(row.InstitutionName, IDENTITY_CLAMP.institution)">
                                    {{ row.InstitutionName ?? '—' }}
                                </span>
                            </td>
                            <td class="col-dept px-3 py-3 text-sm text-tx-body align-top">
                                <span class="line-clamp-2" :title="clampedTitle(row.DepartmentName, IDENTITY_CLAMP.department)">
                                    {{ row.DepartmentName ?? '—' }}
                                </span>
                            </td>
                            <td class="col-acct px-3 py-3 text-sm align-top">
                                <div class="text-tx-body line-clamp-2" :title="clampedTitle(row.AccountDescription, IDENTITY_CLAMP.account)">
                                    {{ row.AccountDescription ?? '—' }}
                                </div>
                                <!-- Fixed-format 27-char identifier. Held to one
                                     line: wrapping it added a whole line to every
                                     row's height for no gain. A tooltip is
                                     warranted here because it genuinely does
                                     truncate at the narrower breakpoints. -->
                                <div class="acct-no text-[10px] text-tx-subtle font-mono mt-1"
                                    :title="row.AccountNumber">
                                    {{ row.AccountNumber ?? '—' }}
                                </div>
                            </td>

                            <td v-for="(m, i) in months" :key="m.key"
                                :data-month-index="i"
                                :style="heatStyle(row, m.key, rowIndex)"
                                :class="[
                                    'col-month px-2.5 py-3 text-[13px] text-right whitespace-nowrap tabular-nums align-top',
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
                                    'col-ytd px-3 py-3 text-sm text-right whitespace-nowrap font-semibold tabular-nums align-top',
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
                            <td colspan="3" class="col-foot-label px-3 py-3 text-left align-middle">
                                <span class="text-[11px] font-semibold uppercase tracking-wider text-tx-subtle">Totals</span>
                                <span class="ml-2 text-[11px] text-tx-muted">
                                    all {{ stats.accountCount }} account{{ stats.accountCount === 1 ? '' : 's' }}
                                </span>
                            </td>

                            <td v-for="(m, i) in months" :key="m.key"
                                :data-month-index="i"
                                :class="[
                                    'col-month px-2.5 py-3 text-[13px] text-right whitespace-nowrap tabular-nums font-semibold',
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
                                    'col-ytd px-3 py-3 text-sm text-right whitespace-nowrap font-bold tabular-nums',
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
/* ── Identity columns: widths + sticky offsets ───────────────────────────────
   Each column's `left` is the running sum of the widths before it, so widths
   and offsets are declared together at every breakpoint. Splitting them across
   utility classes is what lets them drift apart silently.

   The table is inherently wider than any screen — 12 money columns plus four
   identity fields — so the goal is not to avoid scrolling but to keep the row
   identifiable while it happens.

   Breakpoints are chosen against CONTENT width, not viewport: the layout has a
   fixed 18rem sidebar from md up, so a 1024px viewport is really ~700px of
   table. Pinning starts at lg with deliberately tight columns and relaxes as
   real estate appears. Below lg the whole table scrolls — pinning ~20rem of a
   ~430px content area would leave nothing to scroll into. */

.col-inst,
.col-dept,
.col-acct,
.col-ytd {
    /* Opaque base is load-bearing: these cells slide over the month columns, so
       any transparency lets the scrolled content show through them. */
    background-color: rgb(var(--color-surface));
}

/* ── Frozen header and totals row ────────────────────────────────────────────
   The vertical scroll container is <main>, so `top`/`bottom` resolve against the
   content area. Without this, the month headings scroll away after a handful of
   rows and every figure below becomes an unlabelled number.

   Layering matters: cells frozen on two axes must outrank cells frozen on one,
   or the identity columns slide over the header as it scrolls.
     30  header / footer corners (frozen vertically AND horizontally)
     20  header / footer month cells (vertical only)
     10  body identity + YTD columns (horizontal only) */
thead th,
tfoot td {
    position: sticky;
    z-index: 20;
    background-color: rgb(var(--color-surface-2));
}

thead th { top: 0; }
tfoot td { bottom: 0; }

thead .col-inst,
thead .col-dept,
thead .col-acct,
thead .col-ytd,
tfoot .col-foot-label,
tfoot .col-ytd {
    z-index: 30;
}

/* Hairlines drawn as shadows so they ride along with the frozen rows rather than
   scrolling off with the table's own borders. */
thead th { box-shadow: inset 0 -1px 0 rgb(var(--color-line)); }
tfoot td { box-shadow: inset 0 1px 0 rgb(var(--color-line)); }


/* ── Column crosshair ────────────────────────────────────────────────────────
   Applied as a background-COLOR so the per-cell heat shading, which is a
   background-IMAGE, layers on top instead of being overwritten. Cyan against the
   row's amber keeps the two axes readable where they cross. */
.is-col-hover {
    background-color: rgba(14, 165, 233, 0.09);
}
.dark .is-col-hover {
    background-color: rgba(34, 211, 238, 0.1);
}

/* Quarter boundaries: a slightly stronger rule than the row hairlines, so the
   twelve months read as four groups rather than one undifferentiated run. */
.quarter-edge {
    border-left: 1px solid rgb(var(--color-line));
}

/* Row hover must not reintroduce transparency. A translucent tint is layered as
   a background-IMAGE over the opaque background-COLOR, which composites to an
   opaque result — whereas swapping background-color for a /40 tint would make
   the pinned cells see-through exactly while the user is reading them.
   The tint values mirror the row's own `hover:bg-amber-50/40` and
   `dark:hover:bg-amber-900/10` exactly. The unpinned cells composite those over
   the card's surface, so using the same colour and alpha here makes the pinned
   cells land on an identical result — a different amber would make the frozen
   columns read as a separate shade on hover. */
tbody tr:hover .col-inst,
tbody tr:hover .col-dept,
tbody tr:hover .col-acct,
tbody tr:hover .col-ytd {
    background-image: linear-gradient(rgba(255, 251, 235, 0.4), rgba(255, 251, 235, 0.4));
}
.dark tbody tr:hover .col-inst,
.dark tbody tr:hover .col-dept,
.dark tbody tr:hover .col-acct,
.dark tbody tr:hover .col-ytd {
    background-image: linear-gradient(rgba(120, 53, 15, 0.1), rgba(120, 53, 15, 0.1));
}

/* The scroll region is focusable, so it needs a visible focus ring — but only
   for keyboard users, not on the click that usually precedes scrolling. */
.table-scroll:focus {
    outline: none;
}
.table-scroll:focus-visible {
    outline: 2px solid rgba(251, 191, 36, 0.75);
    outline-offset: -2px;
}

/* Fixed layout makes the colgroup widths binding. `width: max-content` sizes the
   table to the sum of those columns so the browser never redistributes spare
   space back into them — a redistribution would shift the real column edges out
   from under the `left` offsets below and reopen the gap. */
.ledger-table {
    table-layout: fixed;
    width: max-content;
}

/* Base — mobile / tablet. No pinning; compact so the row fits in fewer swipes. */
.w-inst  { width: 8rem; }
.w-dept  { width: 8rem; }
.w-acct  { width: 11rem; }
.w-month { width: 5.75rem; }
.w-ytd   { width: 7rem; }

/* lg — pinning begins. Offsets are the running sum of the widths above. */
@media (min-width: 1024px) {
    .col-inst,
    .col-dept,
    .col-acct {
        position: sticky;
        z-index: 10;
    }
    .col-inst { left: 0; }
    .col-dept { left: 8rem; }
    .col-acct {
        left: 16rem;
        /* Depth cue that content passes beneath, which a plain border cannot give. */
        box-shadow: 8px 0 10px -8px rgba(2, 6, 23, 0.28);
    }

    .col-ytd {
        position: sticky;
        right: 0;
        z-index: 10;
        box-shadow: -8px 0 10px -8px rgba(2, 6, 23, 0.28);
    }

    /* The totals label spans the three identity columns, so it freezes as one
       cell at left: 0 rather than needing offsets of its own. */
    tfoot .col-foot-label {
        left: 0;
    }

    /* Corner cells need BOTH the frozen-row hairline and the frozen-column depth
       shadow. A single box-shadow declaration replaces rather than merges, so
       they are combined explicitly here. */
    thead .col-acct {
        box-shadow:
            inset 0 -1px 0 rgb(var(--color-line)),
            8px 0 10px -8px rgba(2, 6, 23, 0.28);
    }
    thead .col-ytd {
        box-shadow:
            inset 0 -1px 0 rgb(var(--color-line)),
            -8px 0 10px -8px rgba(2, 6, 23, 0.28);
    }
    tfoot .col-foot-label {
        box-shadow:
            inset 0 1px 0 rgb(var(--color-line)),
            8px 0 10px -8px rgba(2, 6, 23, 0.28);
    }
    tfoot .col-ytd {
        box-shadow:
            inset 0 1px 0 rgb(var(--color-line)),
            -8px 0 10px -8px rgba(2, 6, 23, 0.28);
    }
}

/* xl — more room for the identity fields, which are cramped at 8rem. */
@media (min-width: 1280px) {
    .w-inst  { width: 9.5rem; }
    .w-dept  { width: 9.5rem; }
    .w-acct  { width: 12rem; }
    .w-month { width: 6rem; }

    .col-dept { left: 9.5rem; }
    .col-acct { left: 19rem; }
}

/* 2xl — full comfort; roughly six months visible alongside the identity block. */
@media (min-width: 1536px) {
    .w-inst  { width: 11rem; }
    .w-dept  { width: 11rem; }
    .w-acct  { width: 13rem; }

    .col-dept { left: 11rem; }
    .col-acct { left: 22rem; }
}

/* Large desktops. Only the month columns grow — widening them costs nothing
   structurally, whereas changing the identity widths would mean re-deriving the
   pinned offsets again. */
@media (min-width: 1920px) {
    .w-month { width: 7rem; }
}

/* The YTD column stays visually separated from the months at every size. */
.col-ytd { border-left: 2px solid rgba(251, 191, 36, 0.4); }

.acct-no {
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
}

/* Fixed layout clips rather than wraps, so long unbroken words in the identity
   columns need explicit permission to break. */
.col-inst,
.col-dept,
.col-acct {
    overflow-wrap: anywhere;
}

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
