import { onMounted, onUnmounted } from 'vue'

/**
 * Left/right arrow keys step between fiscal years.
 *
 * For the pages whose arrows mean only that. The two wide ledger tables
 * (Department Expenditure, Allocation Line Expenditure) have context-sensitive
 * arrows — months while the pointer is in the table, years otherwise — and get
 * theirs from useLedgerTable(), which delegates the year step back to the page
 * via onPrevYear/onNextYear. That is the right seam; do not fold these two
 * behaviours together.
 *
 * Accessors are functions, matching the useLedgerTable() convention, so the
 * handler always reads current props rather than closing over a stale value.
 *
 * @param {object}   options
 * @param {Function} options.fyNav  () => ({ prev, next }) — nulls at the ends
 * @param {Function} options.goToFy (fy) => void
 */
export function useFiscalYearNav({ fyNav, goToFy }) {
    const handleKeydown = (e) => {
        // A focused <select> owns its own arrow-key behaviour; never steal it.
        const tag = document.activeElement?.tagName
        if (tag === 'SELECT' || tag === 'INPUT' || tag === 'TEXTAREA') return

        if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') return

        const nav = fyNav() ?? {}
        const target = e.key === 'ArrowLeft' ? nav.prev : nav.next

        // At the first or last year there is nothing to step to, so leave the
        // event alone rather than swallowing it.
        if (target == null) return

        e.preventDefault()
        goToFy(target)
    }

    onMounted(() => window.addEventListener('keydown', handleKeydown))
    onUnmounted(() => window.removeEventListener('keydown', handleKeydown))
}
