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
 * THE ARROW KEYS ONLY EVER SCROLL THIS TABLE. They did once step the fiscal
 * year when the pointer was outside the table — removed 2026-10-02 on the
 * user's instruction, and the onPrevYear/onNextYear parameters went with it.
 * Do not reintroduce either: a global key handler that renavigates the page is
 * not something a reader can predict from where their pointer happens to be.
 *
 * @param {object}   options
 * @param {Function} options.rowCount     () => number of rendered rows
 * @param {string}   [options.stepSelector] a header cell whose width is one
 *        scroll step. Scrolling by a real column width keeps figures aligned
 *        under their headings, rather than the browser's fixed ~40px nudge.
 */
export function useTableScroll({ rowCount, stepSelector = 'thead [data-scroll-col]' }) {
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

    // ── Arrow keys: this table, or nothing ──────────────────────────────────
    // Over the table the arrows scroll columns, which is what someone reading a
    // row wants. Anywhere else they are LEFT ALONE — the browser keeps whatever
    // they would otherwise do.
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

        // The ONLY case this composable acts on: the user is in a table that has
        // somewhere to scroll. Everything else — pointer outside the table, or
        // inside one that already fits on screen — falls through untouched.
        if (!arrowsScrollTable.value) return

        e.preventDefault()
        scrollColumns(e.key === 'ArrowLeft' ? -1 : 1)
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
