<script setup>
import { useModalShell } from '@/composables/useModalShell';

const props = defineProps({
  open: { type: Boolean, default: false },
  title: { type: String, required: true },
  icon: { type: String, required: true },
  labelId: { type: String, required: true },
});

const emit = defineEmits(['close']);

const close = () => emit('close');

// Escape-to-close and the body scroll lock used to live here. They moved to the
// composable so the lock could be reference counted: these two legal modals are
// mounted on every page via FooterBar, so a page with a modal of its own had
// three in the DOM, and whichever closed first unlocked the page under the
// others. No visual or behavioural change to this component.
useModalShell(() => props.open, close);
</script>

<template>
  <Teleport to="body">
    <Transition name="modal">
      <div
        v-if="open"
        class="fixed inset-0 z-50 flex items-center justify-center p-4 bg-slate-950/50 backdrop-blur-sm"
        role="dialog"
        aria-modal="true"
        :aria-labelledby="labelId"
        @click.self="close"
      >
        <div class="modal-panel bg-surface rounded-2xl shadow-2xl shadow-slate-950/20 max-w-3xl w-full max-h-[85vh] overflow-hidden flex flex-col border border-line">
          <!-- Header — mirrors the page hero: gold accent rail, dot grid, gold icon tile -->
          <div class="relative px-6 py-5 border-b border-line bg-gradient-to-br from-cyan-50 via-white to-slate-100 dark:from-[#0b1625] dark:via-[#0e2040] dark:to-[#0b1625]">
            <div class="absolute inset-0 opacity-[0.18] dark:hidden"
                 style="background-image: radial-gradient(circle at 1px 1px, rgba(8,47,73,0.45) 1px, transparent 0); background-size: 24px 24px;"></div>
            <div class="absolute inset-0 hidden opacity-5 dark:block"
                 style="background-image: radial-gradient(circle at 1px 1px, rgba(255,255,255,0.4) 1px, transparent 0); background-size: 24px 24px;"></div>
            <div class="absolute top-0 left-0 right-0 h-0.5"
                 style="background: linear-gradient(90deg, #0891b2, #d97706 45%, transparent 100%);"></div>

            <div class="relative flex items-center justify-between gap-4">
              <div class="flex items-center gap-3 min-w-0">
                <div
                  class="w-11 h-11 rounded-2xl flex items-center justify-center flex-shrink-0 shadow-lg border border-white/50 dark:border-white/20"
                  style="background: linear-gradient(135deg, rgba(217,119,6,0.75) 0%, rgba(245,158,11,0.55) 100%);"
                >
                  <i :class="icon" class="text-white text-base"></i>
                </div>
                <div class="min-w-0">
                  <p class="text-[10px] font-semibold text-cyan-800 uppercase tracking-widest dark:text-white/50">Legal</p>
                  <h2 :id="labelId" class="font-display text-xl font-bold text-slate-950 leading-tight truncate dark:text-white">
                    {{ title }}
                  </h2>
                </div>
              </div>

              <button
                @click="close"
                class="w-8 h-8 flex items-center justify-center rounded-lg text-tx-subtle hover:text-tx-primary hover:bg-black/5 dark:hover:bg-white/10 transition-colors flex-shrink-0 focus:outline-none focus:ring-2 focus:ring-cyan-500"
                aria-label="Close"
              >
                <i class="fas fa-times"></i>
              </button>
            </div>
          </div>

          <!-- Body -->
          <div class="px-6 py-5 overflow-y-auto flex-1 text-tx-body">
            <slot />
          </div>

          <!-- Footer -->
          <div class="px-6 py-4 border-t border-line bg-surface-2 flex justify-end">
            <button
              @click="close"
              class="px-6 py-2 rounded-lg text-sm font-semibold text-white shadow-sm hover:shadow-md transition-all focus:outline-none focus:ring-2 focus:ring-cyan-500 focus:ring-offset-2 dark:focus:ring-offset-[#0b1625]"
              style="background: linear-gradient(135deg, #0891b2, #b45309);"
            >
              Close
            </button>
          </div>
        </div>
      </div>
    </Transition>
  </Teleport>
</template>

<style scoped>
.modal-enter-active,
.modal-leave-active {
  transition: opacity 0.25s ease;
}

/* A dialog on its way out must not swallow clicks, and this also makes a
   STUCK leave harmless rather than catastrophic. The overlay is fixed inset-0
   with pointer-events auto, so if the leave transition never completes - the
   element stays in the DOM at opacity 0 - it silently covers the whole page
   and nothing is clickable. Observed under an automation harness where
   requestAnimationFrame was throttled to a standstill, so transitionend never
   fired; a real user would need a comparably stalled renderer to reach it.
   One line removes the failure mode entirely. */
.modal-leave-active,
.modal-leave-to {
  pointer-events: none;
}

.modal-enter-from,
.modal-leave-to {
  opacity: 0;
}

.modal-enter-active .modal-panel,
.modal-leave-active .modal-panel {
  transition: transform 0.25s ease;
}

.modal-enter-from .modal-panel,
.modal-leave-to .modal-panel {
  transform: scale(0.96);
}
</style>
