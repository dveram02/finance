import { ref, computed, watch, onMounted, onUnmounted, nextTick } from 'vue'

/**
 * Shared behaviour for the wide fiscal-year ledger tables.
 *
 * Covers the parts that are identical across every such view: measuring whether
 * the table can scroll, the column crosshair, per-row heat shading, and the
 * context-sensitive arrow keys. Column layout stays with each page, because the
 * column sets differ.
 *
 * @param {object}   options
 * @param {Function} options.months     () => array of month descriptors ({ key })
 * @param {Function} options.rows       () => array of the currently rendered rows
 * @param {Function} options.onPrevYear called when ← should step the fiscal year
 * @param {Function} options.onNextYear called when → should step the fiscal year
 */
export function useLedgerTable({ months, rows, onPrevYear, onNextYear }) {
    // ── Scroll affordance ───────────────────────────────────────────────────
    // Whether the table can scroll depends on viewport width, the sidebar, and
    // how wide the identity columns have grown at the current breakpoint — none
    // of which can be decided up front, so measure the element.
    const scroller = ref(null)
    const canScroll = ref(false)
    let resizeObserver = null

    const measureScroll = () => {
        const el = scroller.value
        canScroll.value = !!el && el.scrollWidth - el.clientWidth > 1
    }

    // Row count changes alter scrollWidth without resizing the container, so the
    // observer alone would miss them.
    watch(() => rows().length, () => nextTick(measureScroll))

    // ── Column crosshair ────────────────────────────────────────────────────
    // Delegated, rather than a listener on every one of a few hundred cells.
    const hoveredMonth = ref(null)

    const onTableHover = (e) => {
        const cell = e.target?.closest?.('[data-month-index]')
        hoveredMonth.value = cell ? Number(cell.dataset.monthIndex) : null
    }

    const clearHover = () => {
        hoveredMonth.value = null
    }

    // ── Heat shading ────────────────────────────────────────────────────────
    // Each row is shaded against its OWN largest month, not a table-wide
    // maximum. A global scale would wash every smaller account into a uniform
    // pale band and answer the wrong question — the useful one is "when did THIS
    // account spend".
    const rowPeaks = computed(() =>
        rows().map((row) =>
            Math.max(...months().map((m) => Math.abs(Number(row[m.key]) || 0)), 0)
        )
    )

    // Returned as a background-IMAGE so it layers over the crosshair's
    // background-COLOR instead of replacing it — the two aids must coexist.
    const heatStyle = (row, monthKey, rowIndex) => {
        const value = Number(row[monthKey]) || 0
        const peak = rowPeaks.value[rowIndex] || 0
        if (!value || !peak) return null

        const intensity = Math.abs(value) / peak
        const alpha = (0.035 + intensity * 0.125).toFixed(3)
        const rgb = value < 0 ? '220, 38, 38' : '217, 119, 6'

        return { backgroundImage: `linear-gradient(rgba(${rgb}, ${alpha}), rgba(${rgb}, ${alpha}))` }
    }

    // ── Context-sensitive arrow keys ────────────────────────────────────────
    // Over the table the arrows scroll months, which is what someone reading a
    // row wants; anywhere else they step fiscal years. Without the split, trying
    // to scroll to September silently throws you into a different year.
    //
    // Hover and focus are tracked as state rather than read from
    // document.activeElement, which is not reactive — the page's hint has to
    // re-render when either changes.
    const pointerInTable = ref(false)
    const tableFocused = ref(false)

    const arrowsScrollTable = computed(() =>
        canScroll.value && (pointerInTable.value || tableFocused.value)
    )

    // Scroll by exactly one column so figures stay aligned under their headings,
    // rather than the browser's fixed ~40px nudge. Measured from a real cell
    // because the width changes across breakpoints.
    const monthStep = () => scroller.value?.querySelector('thead [data-month-index]')?.offsetWidth || 96

    const scrollMonths = (direction) => {
        const reduceMotion = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches

        scroller.value?.scrollBy({
            left: direction * monthStep(),
            behavior: reduceMotion ? 'auto' : 'smooth',
        })
    }

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

        const step = direction === -1 ? onPrevYear : onNextYear
        if (step && step() !== false) e.preventDefault()
    }

    onMounted(() => {
        window.addEventListener('keydown', handleKeydown)

        measureScroll()
        if (scroller.value) {
            resizeObserver = new ResizeObserver(measureScroll)
            resizeObserver.observe(scroller.value)
        }
    })

    onUnmounted(() => {
        window.removeEventListener('keydown', handleKeydown)
        resizeObserver?.disconnect()
    })

    return {
        scroller,
        canScroll,
        measureScroll,
        hoveredMonth,
        onTableHover,
        clearHover,
        heatStyle,
        pointerInTable,
        tableFocused,
        arrowsScrollTable,
    }
}
