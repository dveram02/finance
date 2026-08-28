import { ref, computed } from 'vue'
import { useTableScroll } from '@/composables/useTableScroll'

/**
 * Shared behaviour for the wide FISCAL-MONTH ledger tables.
 *
 * Covers the parts that only make sense against a 12-month axis: the column
 * crosshair and the per-row heat shading. Scrolling and the context-sensitive
 * arrow keys live in useTableScroll, which the requisition detail tables also
 * use — they are wide and scroll identically but have no month axis, and
 * sharing that core is what stops the two scroll implementations drifting.
 *
 * Column layout stays with each page, because the column sets differ.
 *
 * @param {object}   options
 * @param {Function} options.months     () => array of month descriptors ({ key })
 * @param {Function} options.rows       () => array of the currently rendered rows
 * @param {Function} options.onPrevYear called when ← should step the fiscal year
 * @param {Function} options.onNextYear called when → should step the fiscal year
 */
export function useLedgerTable({ months, rows, onPrevYear, onNextYear }) {
    const scroll = useTableScroll({
        rowCount: () => rows().length,
        onPrevYear,
        onNextYear,
        // One month column is one scroll step, so figures stay aligned under
        // their headings.
        stepSelector: 'thead [data-month-index]',
    })

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

    return {
        // Scroll surface, unchanged for the pages that already consume it.
        scroller: scroll.scroller,
        canScroll: scroll.canScroll,
        measureScroll: scroll.measureScroll,
        pointerInTable: scroll.pointerInTable,
        tableFocused: scroll.tableFocused,
        arrowsScrollTable: scroll.arrowsScrollTable,

        hoveredMonth,
        onTableHover,
        clearHover,
        heatStyle,
    }
}
