<script setup>
import { ref, computed, onMounted, watch, nextTick } from 'vue'
import { fiscalYearSpan as fySpan } from '@/fiscalYear'

/**
 * The Dashboard's fiscal-year bar — a COMPACT, single-row alternative to
 * FiscalYearHero.
 *
 * WHY THIS IS A SEPARATE COMPONENT (2026-11-02, the user's explicit
 * instruction). The Dashboard must fit on one screen without scrolling, and the
 * tall stacked hero — eyebrow row, then a text-5xl numeral between two h-9
 * steppers, then the rail — cost ~170px of that budget. FiscalYearHero heads
 * ALL SIX pages, so shrinking it there would have changed Budget Allocations,
 * Monthly Expenditure, Variance and both drill-downs too. A `compact` prop was
 * the other option and was rejected: the instruction was "if the component is
 * shared, use a new component for dashboard only".
 *
 * 🔴 So this file is DELIBERATE DUPLICATION, and the cost is drift: a change to
 * the fiscal-year band's look now has two homes. Keep that bounded —
 *   - the Oct→Sep span is NOT re-derived here. It comes from @/fiscalYear,
 *     which is the single definition of that rule and is covered by
 *     `npm run test:js`. Never inline the arithmetic.
 *   - gold stays the fiscal-year identity colour, per the app-wide colour rule.
 *   - arrow keys do NOT step the year. Removed app-wide 2026-10-02; the year
 *     changes only from the stepper and the rail you can see.
 *
 * What this drops relative to the hero, all of it dashboard-specific:
 *   - `controls` / `allYearsLabel`. The Dashboard always has a resolved year and
 *     always wants its stepper, and it has no all-years state — that belongs to
 *     the two drill-downs, which keep the full hero.
 *   - the stacked layout. Everything sits on one flex row that wraps on narrow
 *     screens.
 * The "—" fallback for an absent year is KEPT: an outage resolves no year, and
 * the band still has to render.
 */
const props = defineProps({
    activeFiscalYear: [Number, String],
    currentFiscalYear: [Number, String],
    years: { type: Array, default: () => [] },
    fyNav: { type: Object, default: () => ({ prev: null, next: null }) },
})

const emit = defineEmits(['select'])

const activeYearStr = computed(() => String(props.activeFiscalYear ?? ''))

const hasActiveYear = computed(() =>
    props.activeFiscalYear != null && props.activeFiscalYear !== ''
)

const displayYear = computed(() => props.activeFiscalYear || '—')

// Guarded on hasActiveYear because String(null) === String(null): without it an
// outage that resolved neither year would claim "Current".
const isCurrentFiscalYear = computed(() =>
    hasActiveYear.value && String(props.activeFiscalYear) === String(props.currentFiscalYear)
)

const fiscalYearSpan = computed(() => fySpan(props.activeFiscalYear))

const select = (fy) => {
    if (fy === null || fy === undefined) return
    if (String(fy) === activeYearStr.value) return
    emit('select', fy)
}

// ── Year rail: keep the active year in view ─────────────────────────────────
// The Dashboard's `years` is scoped to years with BUDGET data, so the rail is
// short today (vw_BudgetAllocation starts at FY2025) and will not overflow. It
// grows by one each fiscal year, so the centring is kept rather than assumed
// away.
const yearRail = ref(null)

const scrollActiveIntoView = (behavior = 'smooth') => {
    nextTick(() => {
        const reduceMotion = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches
        const el = yearRail.value?.querySelector('[data-active="true"]')
        el?.scrollIntoView({
            inline: 'center',
            block: 'nearest',
            behavior: reduceMotion ? 'auto' : behavior,
        })
    })
}

onMounted(() => scrollActiveIntoView('auto'))

// The Dashboard navigates with preserveState: true, so Inertia REUSES this
// instance and onMounted does not fire again on a year change.
watch(activeYearStr, () => scrollActiveIntoView())

defineExpose({ scrollActiveIntoView })
</script>

<template>
    <section class="relative overflow-hidden rounded-xl border border-white/60 shadow-lg shadow-slate-950/5 dark:border-white/10">
        <div class="absolute inset-0 bg-gradient-to-br from-cyan-50 via-white to-slate-100 dark:from-[#0b1625] dark:via-[#14213d] dark:to-[#0b1625]"></div>
        <!-- Radial dot texture -->
        <div class="absolute inset-0 opacity-[0.18] dark:hidden"
            style="background-image: radial-gradient(circle at 1px 1px, rgba(8,47,73,0.45) 1px, transparent 0); background-size: 22px 22px;"></div>
        <div class="absolute inset-0 hidden opacity-[0.06] dark:block"
            style="background-image: radial-gradient(circle at 1px 1px, rgba(255,255,255,0.5) 1px, transparent 0); background-size: 22px 22px;"></div>
        <!-- Gold filament along the top edge — fiscal-year identity -->
        <div class="absolute top-0 inset-x-0 h-px"
            style="background: linear-gradient(90deg, transparent, #d97706 25%, #fbbf24 50%, #d97706 75%, transparent);"></div>

        <div class="relative px-4 sm:px-5 py-2">
            <div class="flex flex-wrap items-center justify-between gap-x-5 gap-y-2">

                <!-- Scope: label · stepper · numeral · span.
                     Left-aligned. A centred variant was tried on 2026-11-02 (a
                     three-track grid, because `justify-center` alone drifts as
                     the "Current" badge and the rail change width) and reverted
                     at the user's request the same day. -->
                <div class="flex items-center gap-2.5 sm:gap-3">
                    <span class="hidden sm:inline-flex items-center gap-1.5 text-[10px] font-semibold uppercase tracking-[0.2em] text-cyan-800 dark:text-amber-300/90">
                        <i class="fas fa-calendar-day text-[10px]"></i>
                        Fiscal Year
                    </span>

                    <div class="flex items-center gap-1.5">
                        <button
                            @click="select(fyNav?.prev)" :disabled="!fyNav?.prev"
                            title="Previous fiscal year" aria-label="Previous fiscal year"
                            class="group grid place-items-center h-7 w-7 flex-shrink-0 rounded-full border border-cyan-700/15 bg-white/60 text-xs text-cyan-800 backdrop-blur-sm transition hover:border-amber-400/60 hover:text-amber-700 hover:bg-white disabled:opacity-25 disabled:cursor-not-allowed dark:border-white/15 dark:bg-white/5 dark:text-blue-100/80 dark:hover:border-amber-300/50 dark:hover:text-amber-200 dark:hover:bg-white/10 dark:disabled:hover:border-white/15 dark:disabled:hover:text-blue-100/80 dark:disabled:hover:bg-white/5">
                            <i class="fas fa-chevron-left transition-transform group-hover:-translate-x-0.5"></i>
                        </button>

                        <div class="flex items-baseline gap-2 min-w-[7.5rem] justify-center">
                            <transition name="fy" mode="out-in">
                                <span :key="activeYearStr"
                                    class="fy-numeral font-display text-2xl font-bold leading-none text-slate-950 tabular-nums dark:text-white">
                                    {{ displayYear }}
                                </span>
                            </transition>
                            <p class="text-[11px] font-medium text-slate-600 tracking-wide whitespace-nowrap dark:text-blue-100/60">
                                {{ fiscalYearSpan }}
                            </p>
                        </div>

                        <button
                            @click="select(fyNav?.next)" :disabled="!fyNav?.next"
                            title="Next fiscal year" aria-label="Next fiscal year"
                            class="group grid place-items-center h-7 w-7 flex-shrink-0 rounded-full border border-cyan-700/15 bg-white/60 text-xs text-cyan-800 backdrop-blur-sm transition hover:border-amber-400/60 hover:text-amber-700 hover:bg-white disabled:opacity-25 disabled:cursor-not-allowed dark:border-white/15 dark:bg-white/5 dark:text-blue-100/80 dark:hover:border-amber-300/50 dark:hover:text-amber-200 dark:hover:bg-white/10 dark:disabled:hover:border-white/15 dark:disabled:hover:text-blue-100/80 dark:disabled:hover:bg-white/5">
                            <i class="fas fa-chevron-right transition-transform group-hover:translate-x-0.5"></i>
                        </button>
                    </div>
                </div>

                <!-- Current badge · year rail -->
                <div class="flex items-center gap-2.5 sm:gap-3">
                    <span v-if="isCurrentFiscalYear"
                        class="inline-flex items-center gap-1.5 rounded-full bg-amber-100 ring-1 ring-amber-300/70 px-2 py-0.5 text-[10px] font-bold uppercase tracking-wider text-amber-800 dark:bg-amber-400/15 dark:ring-amber-300/40 dark:text-amber-200">
                        <span class="relative flex h-1.5 w-1.5">
                            <span class="absolute inline-flex h-full w-full animate-ping rounded-full bg-amber-300 opacity-75"></span>
                            <span class="relative inline-flex h-1.5 w-1.5 rounded-full bg-amber-300"></span>
                        </span>
                        Current
                    </span>

                    <div v-if="years.length" ref="yearRail"
                        role="tablist" aria-label="Select fiscal year"
                        class="year-rail flex items-center gap-1.5 overflow-x-auto -mx-1 px-1">
                        <button v-for="year in years" :key="year"
                            role="tab"
                            :data-active="String(year) === activeYearStr"
                            :aria-selected="String(year) === activeYearStr"
                            @click="select(year)"
                            :class="[
                                'flex-shrink-0 rounded-full px-2.5 py-0.5 text-xs font-semibold tabular-nums transition-all duration-200',
                                String(year) === activeYearStr
                                    ? 'bg-gradient-to-b from-amber-300 to-amber-500 text-[#1a1205] shadow shadow-amber-500/20'
                                    : 'bg-white/70 text-cyan-800 ring-1 ring-cyan-700/10 hover:bg-cyan-50 hover:text-cyan-950 dark:bg-white/5 dark:text-blue-100/70 dark:ring-white/10 dark:hover:bg-white/10 dark:hover:text-white',
                                String(year) === String(currentFiscalYear) && String(year) !== activeYearStr
                                    ? 'ring-1 ring-dashed ring-amber-300/50' : '',
                            ]">
                            {{ year }}
                        </button>
                    </div>
                </div>

            </div>
        </div>
    </section>
</template>

<style scoped>
/* Fiscal-year numeral transition — replays on every year change via :key.
   Shorter travel than the hero's, because the numeral is text-2xl here and the
   hero's 0.35em drop reads as a jump at this size. */
.fy-enter-active {
    animation: fyIn 0.4s cubic-bezier(0.16, 1, 0.3, 1);
}
.fy-leave-active {
    animation: fyOut 0.18s ease-in forwards;
}
@keyframes fyIn {
    0%   { opacity: 0; transform: translateY(0.2em) scale(0.96); filter: blur(4px); }
    100% { opacity: 1; transform: translateY(0)     scale(1);    filter: blur(0); }
}
@keyframes fyOut {
    0%   { opacity: 1; transform: translateY(0)      scale(1); }
    100% { opacity: 0; transform: translateY(-0.18em) scale(0.98); }
}

/* Slim year-rail scrollbar */
.year-rail::-webkit-scrollbar { height: 4px; }
.year-rail::-webkit-scrollbar-track { background: transparent; }
.year-rail::-webkit-scrollbar-thumb {
    background: rgba(251, 191, 36, 0.28);
    border-radius: 9999px;
}
.year-rail::-webkit-scrollbar-thumb:hover { background: rgba(251, 191, 36, 0.5); }
</style>
