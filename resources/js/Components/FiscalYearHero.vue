<script setup>
import { ref, computed, onMounted, watch, nextTick } from 'vue'
import { fiscalYearSpan as fySpan } from '@/fiscalYear'

/**
 * The fiscal-year navigator that heads every ledger page. Extracted so the
 * views cannot drift apart visually — it was previously copied per page.
 *
 * Owns presentation and the year rail only; the parent decides what changing
 * year means, via the `select` event.
 */
const props = defineProps({
    activeFiscalYear:  [Number, String],
    currentFiscalYear: [Number, String],
    years:             { type: Array, default: () => [] },
    fyNav:             { type: Object, default: () => ({ prev: null, next: null }) },
})

const emit = defineEmits(['select'])

const activeYearStr = computed(() => String(props.activeFiscalYear ?? ''))

const isCurrentFiscalYear = computed(() =>
    String(props.activeFiscalYear) === String(props.currentFiscalYear)
)

// Fiscal year N runs Oct (N-1) → Sep N. The rule lives in @/fiscalYear because
// the two requisition detail pages' period chip states the same span and had no
// hero to take it from — two copies of an Oct→Sep derivation is how they drift.
// The template is unchanged, so the four pages using this hero are untouched.
const fiscalYearSpan = computed(() => fySpan(props.activeFiscalYear))

const select = (fy) => {
    if (fy === null || fy === undefined) return
    if (String(fy) === activeYearStr.value) return
    emit('select', fy)
}

// ── Year rail: keep the active year in view ─────────────────────────────────
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

// Jump on first paint (an animated scroll as the page appears reads as a
// glitch); glide on every later change.
onMounted(() => scrollActiveIntoView('auto'))

// Every page navigates with preserveState: true, which tells Inertia to REUSE
// this instance rather than remount it — so onMounted does not fire again and
// the rail would otherwise never re-centre after a year change.
watch(activeYearStr, () => scrollActiveIntoView())

defineExpose({ scrollActiveIntoView })
</script>

<template>
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
                    @click="select(fyNav?.prev)" :disabled="!fyNav?.prev"
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
                    @click="select(fyNav?.next)" :disabled="!fyNav?.next"
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
                        @click="select(year)"
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
.year-rail::-webkit-scrollbar { height: 5px; }
.year-rail::-webkit-scrollbar-track { background: transparent; }
.year-rail::-webkit-scrollbar-thumb {
    background: rgba(251, 191, 36, 0.28);
    border-radius: 9999px;
}
.year-rail::-webkit-scrollbar-thumb:hover { background: rgba(251, 191, 36, 0.5); }
</style>
