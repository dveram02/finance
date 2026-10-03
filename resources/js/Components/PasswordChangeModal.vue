<script setup>
import { nextTick, ref, watch } from 'vue'
import { useForm } from '@inertiajs/vue3'
import InputError from '@/Components/InputError.vue'
import { useModalShell } from '@/composables/useModalShell'

const props = defineProps({
  open: { type: Boolean, default: false },
})

const emit = defineEmits(['close'])

// The field names are load-bearing: Laravel's TrimStrings middleware exempts
// exactly current_password / password / password_confirmation, so renaming any
// of them would silently trim a password ending in a space and lock the user
// out at their next sign-in.
const form = useForm({
  current_password: '',
  password: '',
  password_confirmation: '',
})

const show = ref({ current: false, next: false, confirm: false })
const currentPasswordInput = ref(null)

// Captured when the dialog opens so focus can go back where it came from —
// otherwise closing drops the caret at the top of the document and a keyboard
// user has to tab all the way back to the button they just pressed.
let triggerElement = null

const close = () => emit('close')

// An in-flight request must not have its dialog yanked away: the write is
// already on its way to SQL Server, and the user would be left with no idea
// whether it landed.
const { requestClose } = useModalShell(() => props.open, close, {
  canClose: () => !form.processing,
})

const reset = () => {
  form.reset()
  form.clearErrors()
  show.value = { current: false, next: false, confirm: false }
}

watch(
  () => props.open,
  (isOpen) => {
    if (isOpen) {
      triggerElement = document.activeElement
      nextTick(() => currentPasswordInput.value?.focus())
      return
    }

    reset()
    triggerElement?.focus?.()
    triggerElement = null
  },
)

const submit = () => form.post(route('profile.password.update'), {
  preserveScroll: true,

  // A validation failure (422) lands in onError and the dialog deliberately
  // STAYS OPEN — the field errors render beside the inputs that caused them.
  //
  // The throttle path also arrives here as a success: the limiter returns a
  // redirect with an `error` flash and no validation errors, which Inertia
  // treats as a completed visit. Closing on that would discard everything the
  // user typed over something they can retry in a minute, so check the flash
  // on the page that came back rather than assuming any 2xx means it worked.
  onSuccess: (page) => {
    if (page.props.flash?.error) {
      return
    }

    close()
  },

  onError: () => {
    form.reset('current_password', 'password', 'password_confirmation')
    nextTick(() => currentPasswordInput.value?.focus())
  },
})
</script>

<template>
  <Teleport to="body">
    <Transition name="modal">
      <div
        v-if="open"
        class="fixed inset-0 z-50 flex items-center justify-center p-4 bg-slate-950/50 backdrop-blur-sm"
        role="dialog"
        aria-modal="true"
        aria-labelledby="password-modal-title"
        @click.self="requestClose"
      >
        <div class="modal-panel bg-surface rounded-2xl shadow-2xl shadow-slate-950/20 max-w-lg w-full max-h-[90vh] overflow-hidden flex flex-col border border-line">

          <!-- Header — same language as the page hero and the legal modals -->
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
                  <i class="fas fa-key text-white text-base"></i>
                </div>
                <div class="min-w-0">
                  <p class="text-[10px] font-semibold text-cyan-800 uppercase tracking-widest dark:text-white/50">Security</p>
                  <h2 id="password-modal-title" class="font-display text-xl font-bold text-slate-950 leading-tight truncate dark:text-white">
                    Change Password
                  </h2>
                </div>
              </div>

              <button
                type="button"
                @click="requestClose"
                :disabled="form.processing"
                class="w-8 h-8 flex items-center justify-center rounded-lg text-tx-subtle hover:text-tx-primary hover:bg-black/5 dark:hover:bg-white/10 transition-colors flex-shrink-0 focus:outline-none focus:ring-2 focus:ring-cyan-500 disabled:opacity-40 disabled:cursor-not-allowed"
                aria-label="Close"
              >
                <i class="fas fa-times"></i>
              </button>
            </div>
          </div>

          <!-- Body -->
          <form id="password-change-form" @submit.prevent="submit" class="px-6 py-5 space-y-5 overflow-y-auto flex-1">

            <p class="text-xs text-tx-subtle leading-relaxed">
              This is the password for your SWRHA account. Changing it here changes it for
              <strong class="font-semibold text-tx-body">every SWRHA application that uses this account</strong>,
              not just the Finance Portal.
            </p>

            <!-- Current password -->
            <div>
              <label for="current_password" class="mb-2 block text-sm font-semibold text-tx-body">Current password</label>
              <div class="relative">
                <span class="pointer-events-none absolute left-4 top-1/2 -translate-y-1/2 text-tx-subtle">
                  <i class="fa-solid fa-lock"></i>
                </span>
                <input
                  id="current_password"
                  ref="currentPasswordInput"
                  v-model="form.current_password"
                  :type="show.current ? 'text' : 'password'"
                  required
                  maxlength="255"
                  autocomplete="current-password"
                  class="w-full rounded-xl border border-line bg-surface-2 py-3 pl-11 pr-12 text-sm text-tx-primary shadow-sm transition focus:border-cyan-500 focus:outline-none focus:ring-4 focus:ring-cyan-500/15"
                  placeholder="Enter your current password"
                />
                <button
                  type="button"
                  @click="show.current = !show.current"
                  class="absolute right-3 top-1/2 flex h-8 w-8 -translate-y-1/2 items-center justify-center rounded-full text-tx-subtle transition hover:bg-surface hover:text-tx-primary focus:outline-none focus:ring-2 focus:ring-cyan-500"
                  :aria-label="show.current ? 'Hide current password' : 'Show current password'"
                >
                  <i :class="show.current ? 'fa-solid fa-eye-slash' : 'fa-solid fa-eye'"></i>
                </button>
              </div>
              <InputError class="mt-2" :message="form.errors.current_password" />
            </div>

            <!-- New password -->
            <div>
              <label for="password" class="mb-2 block text-sm font-semibold text-tx-body">New password</label>
              <div class="relative">
                <span class="pointer-events-none absolute left-4 top-1/2 -translate-y-1/2 text-tx-subtle">
                  <i class="fa-solid fa-key"></i>
                </span>
                <input
                  id="password"
                  v-model="form.password"
                  :type="show.next ? 'text' : 'password'"
                  required
                  minlength="6"
                  maxlength="64"
                  autocomplete="new-password"
                  class="w-full rounded-xl border border-line bg-surface-2 py-3 pl-11 pr-12 text-sm text-tx-primary shadow-sm transition focus:border-cyan-500 focus:outline-none focus:ring-4 focus:ring-cyan-500/15"
                  placeholder="Enter a new password"
                />
                <button
                  type="button"
                  @click="show.next = !show.next"
                  class="absolute right-3 top-1/2 flex h-8 w-8 -translate-y-1/2 items-center justify-center rounded-full text-tx-subtle transition hover:bg-surface hover:text-tx-primary focus:outline-none focus:ring-2 focus:ring-cyan-500"
                  :aria-label="show.next ? 'Hide new password' : 'Show new password'"
                >
                  <i :class="show.next ? 'fa-solid fa-eye-slash' : 'fa-solid fa-eye'"></i>
                </button>
              </div>
              <p class="mt-2 text-xs text-tx-subtle">
                6 to 64 characters. Letters, numbers, spaces and standard keyboard symbols only —
                accented or non-English characters are not supported by the account system.
              </p>
              <InputError class="mt-2" :message="form.errors.password" />
            </div>

            <!-- Confirmation -->
            <div>
              <label for="password_confirmation" class="mb-2 block text-sm font-semibold text-tx-body">Confirm new password</label>
              <div class="relative">
                <span class="pointer-events-none absolute left-4 top-1/2 -translate-y-1/2 text-tx-subtle">
                  <i class="fa-solid fa-check-double"></i>
                </span>
                <input
                  id="password_confirmation"
                  v-model="form.password_confirmation"
                  :type="show.confirm ? 'text' : 'password'"
                  required
                  maxlength="64"
                  autocomplete="new-password"
                  class="w-full rounded-xl border border-line bg-surface-2 py-3 pl-11 pr-12 text-sm text-tx-primary shadow-sm transition focus:border-cyan-500 focus:outline-none focus:ring-4 focus:ring-cyan-500/15"
                  placeholder="Re-enter the new password"
                />
                <button
                  type="button"
                  @click="show.confirm = !show.confirm"
                  class="absolute right-3 top-1/2 flex h-8 w-8 -translate-y-1/2 items-center justify-center rounded-full text-tx-subtle transition hover:bg-surface hover:text-tx-primary focus:outline-none focus:ring-2 focus:ring-cyan-500"
                  :aria-label="show.confirm ? 'Hide confirmation' : 'Show confirmation'"
                >
                  <i :class="show.confirm ? 'fa-solid fa-eye-slash' : 'fa-solid fa-eye'"></i>
                </button>
              </div>
              <InputError class="mt-2" :message="form.errors.password_confirmation" />
            </div>

            <p class="text-xs text-tx-subtle">
              You will stay signed in here, but signed out on other devices.
            </p>
          </form>

          <!-- Footer -->
          <div class="px-6 py-4 border-t border-line bg-surface-2 flex justify-end gap-3">
            <button
              type="button"
              @click="requestClose"
              :disabled="form.processing"
              class="px-5 py-2 rounded-lg text-sm font-semibold text-tx-body bg-surface border border-line hover:bg-surface-2 transition-colors focus:outline-none focus:ring-2 focus:ring-cyan-500 disabled:opacity-50 disabled:cursor-not-allowed"
            >
              Cancel
            </button>
            <button
              type="submit"
              form="password-change-form"
              :disabled="form.processing"
              class="inline-flex items-center gap-2 px-6 py-2 rounded-lg text-sm font-semibold text-white shadow-sm hover:shadow-md transition-all focus:outline-none focus:ring-2 focus:ring-cyan-500 focus:ring-offset-2 disabled:opacity-60 disabled:cursor-not-allowed dark:focus:ring-offset-[#0b1625]"
              style="background: linear-gradient(135deg, #0891b2, #b45309);"
            >
              <span v-if="!form.processing">Update password</span>
              <span v-else class="flex items-center gap-2">
                <svg class="h-4 w-4 animate-spin" fill="none" viewBox="0 0 24 24">
                  <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                  <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
                </svg>
                Updating
              </span>
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
