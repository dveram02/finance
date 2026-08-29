import { ref, computed, watch, onMounted, onUnmounted, nextTick } from 'vue'

/**
 * Horizontal scrolling for a wide table, and the arrow keys that drive it.
 *
 * Extracted from useLedgerTable so the requisition detail tables can have
 * IDENTICAL scroll behaviour to Monthly Expenditure without inheriting the
 * parts of that composable which only make sense against a 12-month axis (the
 * column crosshair and the per-row heat shading). useLedgerTable now builds on
 * this rather than duplicating it, so the two cannot drift apart.
 *
 * Everything here is measured rather than assumed: whether a table can scroll
 * depends on the viewport, the fixed 18rem sidebar, and how wide the frozen
 * columns have grown at the current breakpoint, none of which can be decided
 * up front.
 *
 * @param {object}   options
 * @param {Function} options.rowCount     () => number of rendered rows
 * @param {Function} options.onPrevYear   called when ← should step the fiscal year
 * @param {Function} options.onNextYear   called when → should step the fiscal year
 * @param {string}   [options.stepSelector] a header cell whose width is one
 *        scroll step. Scrolling by a real column width keeps figures aligned
 *        under their headings, rather than the browser's fixed ~40px nudge.
 */
export function useTableScroll({ rowCount, onPrevYear, onNextYear, stepSelector = 'thead [data-scroll-col]' }) {
    const scroller = ref(null)
    const canScroll = ref(false)
    let resizeObserver = null

    const measureScroll = () => {
        const el = scroller.value
        canScroll.value = !!el && el.scrollWidth - el.clientWidth > 1
    }

    // A row-count change alters scrollWidth without resizing the container, so
    // the ResizeObserver alone would miss it.
    watch(() => rowCount(), () => nextTick(measureScroll))

    // ── Context-sensitive arrow keys ────────────────────────────────────────
    // Over the table the arrows scroll columns, which is what someone reading a
    // row wants; anywhere else they step fiscal years. Without the split, trying
    // to scroll to the last column silently throws you into a different year.
    //
    // Hover and focus are tracked as state rather than read from
    // document.activeElement, which is not reactive — the page's hint has to
    // re-render when either changes.
    const pointerInTable = ref(false)
    const tableFocused = ref(false)

    const arrowsScrollTable = computed(() =>
        canScroll.value && (pointerInTable.value || tableFocused.value)
    )

    const columnStep = () => scroller.value?.querySelector(stepSelector)?.offsetWidth || 96

    const scrollColumns = (direction) => {
        const reduceMotion = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches

        scroller.value?.scrollBy({
            left: direction * columnStep(),
            behavior: reduceMotion ? 'auto' : 'smooth',
        })
    }

    const handleKeydown = (e) => {
        // A focused <select> owns its own arrow-key behaviour; never steal it.
        const tag = document.activeElement?.tagName
        if (tag === 'SELECT' || tag === 'INPUT' || tag === 'TEXTAREA') return

        if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') return

        const direction = e.key === 'ArrowLeft' ? -1 : 1

        // The table wins while the user is in it — but only if there is anything
        // to scroll, so on a wide screen the arrows still step fiscal years.
        if (arrowsScrollTable.value) {
            e.preventDefault()
            scrollColumns(direction)

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
        pointerInTable,
        tableFocused,
        arrowsScrollTable,
        scrollColumns,
    }
}
