/**
 * useDarkMode.js — Dark-mode singleton composable
 *
 * Usage:
 *   const { isDark, toggle, init } = useDarkMode()
 *
 *   init()   — call once on mount (AppLayout + GuestLayout).
 *              Reads localStorage key "theme" ('dark' | 'light'), falls back
 *              to OS prefers-color-scheme when no key is set.
 *              Applies / removes <html class="dark">.
 *
 *   toggle() — flip mode, persist to localStorage, update <html> class.
 *
 *   isDark   — reactive boolean ref; import in any component that needs it
 *              (e.g. SideBar for logo, HeaderBar for the pill toggle).
 *
 * The module-level ref is a singleton: all component instances share the same
 * reactive state without a store or provide/inject.
 */
import { ref } from 'vue'

const isDark = ref(false)
let osListenerRegistered = false

export function useDarkMode() {
    function applyClass() {
        document.documentElement.classList.toggle('dark', isDark.value)
    }

    function init() {
        const saved = localStorage.getItem('theme')
        if (saved !== null) {
            // Explicit user preference stored from a previous toggle
            isDark.value = saved === 'dark'
        } else {
            // No manual preference — honour the OS setting
            isDark.value = window.matchMedia('(prefers-color-scheme: dark)').matches
        }
        applyClass()

        // Keep in sync with OS preference changes (only when no manual pref is set)
        // Guard prevents duplicate listeners when both AppLayout and GuestLayout
        // call init() during the same page session.
        if (!osListenerRegistered) {
            osListenerRegistered = true
            window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', (e) => {
                if (localStorage.getItem('theme') === null) {
                    isDark.value = e.matches
                    applyClass()
                }
            })
        }
    }

    function toggle() {
        isDark.value = !isDark.value
        localStorage.setItem('theme', isDark.value ? 'dark' : 'light')
        applyClass()
    }

    return { isDark, toggle, init }
}
