import { onBeforeUnmount, onMounted, watch } from 'vue'

/**
 * The behaviour every modal in this app needs: Escape to close, and locking the
 * page behind the overlay so it cannot scroll.
 *
 * Only the BEHAVIOUR is shared — each modal keeps its own chrome, the same way
 * useTableScroll shares scrolling while every wide table keeps its own column
 * layout. A shared visual shell was tried once for the page heroes (PageHero)
 * and deleted.
 *
 * The scroll lock is REFERENCE COUNTED, and that is the point of putting it
 * here rather than in each component. AppLayout renders FooterBar, which
 * renders PolicyModals, so the two legal modals are mounted on EVERY
 * authenticated page — any page that adds a modal of its own then has three in
 * the DOM at once. Each one setting `document.body.style.overflow = ''` on its
 * own close means closing one unlocks scrolling underneath another that is
 * still open. The counter makes the last one out restore it, and it restores
 * whatever was there before rather than assuming ''.
 */

let lockCount = 0
let overflowBeforeFirstLock = null

function lockBodyScroll() {
    if (lockCount === 0) {
        overflowBeforeFirstLock = document.body.style.overflow
        document.body.style.overflow = 'hidden'
    }

    lockCount += 1
}

function unlockBodyScroll() {
    if (lockCount === 0) {
        return
    }

    lockCount -= 1

    if (lockCount === 0) {
        document.body.style.overflow = overflowBeforeFirstLock ?? ''
        overflowBeforeFirstLock = null
    }
}

/**
 * @param {() => boolean} isOpen   getter for the modal's open state
 * @param {() => void}    close    what to do when the user asks to close
 * @param {{ canClose?: () => boolean }} options
 *        canClose gates Escape AND the returned requestClose(), so a modal
 *        mid-submit can refuse to vanish out from under an in-flight request.
 */
export function useModalShell(isOpen, close, options = {}) {
    const canClose = options.canClose ?? (() => true)

    // Tracked per instance so a component can never release a lock it does not
    // hold — double-unlocking would free the page while another modal is up.
    let holdsLock = false

    const syncLock = (open) => {
        if (open && !holdsLock) {
            lockBodyScroll()
            holdsLock = true
        } else if (!open && holdsLock) {
            unlockBodyScroll()
            holdsLock = false
        }
    }

    const requestClose = () => {
        if (canClose()) {
            close()
        }
    }

    const handleEscape = (event) => {
        if (event.key === 'Escape' && isOpen()) {
            requestClose()
        }
    }

    watch(isOpen, syncLock, { immediate: true })

    onMounted(() => document.addEventListener('keydown', handleEscape))

    onBeforeUnmount(() => {
        document.removeEventListener('keydown', handleEscape)
        // Unmounting while open must not strand the lock at a non-zero count.
        syncLock(false)
    })

    return { requestClose }
}
