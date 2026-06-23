<script setup>
import { ref, reactive, onMounted } from 'vue'
import { router } from '@inertiajs/vue3'
import { useDarkMode } from '@/composables/useDarkMode'

import SideBar from '@/Components/SideBar.vue'
import HeaderBar from '@/Components/HeaderBar.vue'
import FooterBar from '@/Components/FooterBar.vue'

const { init } = useDarkMode()

const props = defineProps({
  auth: { type: Object, required: true }
})

const mobileOpen = ref(false)
const active = ref('')
const isLoading = ref(false)

function toggleMobile() {
  mobileOpen.value = !mobileOpen.value
}

function signOut() {
  router.post(route('logout'))
}

function scrollToTop() {
  window.scrollTo({ top: 0, behavior: 'smooth' })
}

const model = reactive({
  range: '30',
  department: 'all',
  lastUpdated: new Date().toLocaleString('en-US', {
    hour: 'numeric',
    minute: 'numeric',
    hour12: true
  }),
  countdown: 23
})

// Update timestamp every minute
setInterval(() => {
  model.lastUpdated = new Date().toLocaleString('en-US', {
    hour: 'numeric',
    minute: 'numeric',
    hour12: true
  })
}, 60000)

// Countdown timer
setInterval(() => {
  if (model.countdown > 0) {
    model.countdown--
  } else {
    model.countdown = 23
  }
}, 60000)

// Track navigation loading state
router.on('start', () => { isLoading.value = true })
router.on('finish', () => {
  isLoading.value = false
  mobileOpen.value = false
  active.value = ''
})

onMounted(() => {
  document.body.classList.add('page-loaded')
  // Initialise dark mode from localStorage / OS preference.
  // The inline script in app.blade.php prevents the initial FOUC;
  // init() here wires up the reactive ref and the OS-change listener.
  init()
})
</script>

<template>
  <!-- Root wrapper — dark gradient in dark mode, light gradient in light mode -->
  <div class="relative flex flex-col min-h-screen overflow-hidden bg-[#eef3f6] transition-colors duration-300 dark:bg-[#07111f]">
    <div class="pointer-events-none fixed inset-0 bg-[radial-gradient(circle_at_18%_0%,rgba(14,116,144,0.14),transparent_28%),radial-gradient(circle_at_88%_8%,rgba(245,158,11,0.12),transparent_24%),linear-gradient(135deg,#f8fafc_0%,#eef3f6_45%,#dde8ef_100%)] dark:bg-[radial-gradient(circle_at_18%_0%,rgba(34,211,238,0.12),transparent_28%),radial-gradient(circle_at_88%_8%,rgba(245,158,11,0.1),transparent_24%),linear-gradient(135deg,#07111f_0%,#0c1c2f_48%,#102638_100%)]"></div>
    <div class="pointer-events-none fixed inset-0 opacity-[0.18] dark:opacity-[0.12]" style="background-image: linear-gradient(rgba(15, 23, 42, .11) 1px, transparent 1px), linear-gradient(90deg, rgba(15, 23, 42, .11) 1px, transparent 1px); background-size: 44px 44px;"></div>

    <!-- Sidebar -->
    <SideBar
      :auth="auth"
      :mobile-open="mobileOpen"
      :active="active"
      @activate="active = $event"
      @signout="signOut"
      @close-mobile="mobileOpen = false"
    />

    <!-- Mobile overlay with blur -->
    <transition
      enter-active-class="transition-opacity duration-300 ease-out"
      enter-from-class="opacity-0"
      enter-to-class="opacity-100"
      leave-active-class="transition-opacity duration-200 ease-in"
      leave-from-class="opacity-100"
      leave-to-class="opacity-0"
    >
      <div
        v-if="mobileOpen"
        class="fixed inset-0 bg-black/40 backdrop-blur-sm z-40 md:hidden"
        @click="toggleMobile"
      ></div>
    </transition>

    <!-- Main layout container -->
    <div class="relative z-10 flex flex-col flex-1 md:ml-72 overflow-hidden transition-all duration-300">

      <!-- Header -->
      <HeaderBar
        :model="model"
        @toggle-mobile="toggleMobile"
        :auth="auth"
        :is-loading="isLoading"
      />

      <!-- Main content -->
      <main class="flex-1 overflow-y-auto">
        <div class="px-5 sm:px-7 py-5 sm:py-6 animate-fade-in">

          <!-- Breadcrumb -->
          <nav class="mb-5 flex items-center space-x-2 text-xs text-tx-subtle">
            <a href="/" class="hover:text-tx-primary transition-colors duration-200">
              <i class="fas fa-home"></i>
            </a>
            <i class="fas fa-chevron-right text-[9px] opacity-50"></i>
            <span class="font-medium text-tx-muted">{{ $page.component.replace(/\//g, ' / ') }}</span>
          </nav>

          <!-- Page content -->
          <div class="space-y-5">
            <slot />
          </div>
        </div>
      </main>

      <!-- Footer -->
      <FooterBar />
    </div>

    <!-- Toast container (reserved) -->
    <div class="fixed bottom-4 right-4 z-50 space-y-2 max-w-sm"></div>

    <!-- Back to top button -->
    <button
      @click="scrollToTop"
      class="fixed bottom-7 right-7 w-10 h-10 text-white
             rounded-full shadow-lg hover:shadow-xl hover:scale-110 transition-all duration-300
             flex items-center justify-center z-40
             opacity-0 pointer-events-none md:opacity-100 md:pointer-events-auto"
      style="background: linear-gradient(135deg, #0891b2, #b45309);"
      aria-label="Back to top"
    >
      <i class="fas fa-arrow-up text-xs"></i>
    </button>
  </div>
</template>

<style>
/* Global animations */
@keyframes fade-in {
  from { opacity: 0; transform: translateY(10px); }
  to   { opacity: 1; transform: translateY(0); }
}

@keyframes loading {
  0%   { transform: translateX(-100%); }
  100% { transform: translateX(100%); }
}

.animate-fade-in  { animation: fade-in 0.4s ease-out; }
.animate-loading  { animation: loading 1.5s ease-in-out infinite; }
.page-loaded      { animation: fade-in 0.3s ease-out; }

/* Touch targets */
@media (max-width: 768px) {
  button, a { min-height: 44px; min-width: 44px; }
}

/* Focus styles */
*:focus-visible {
  outline: 2px solid #3b82f6;
  outline-offset: 2px;
  border-radius: 4px;
}

/* Print */
@media print {
  .no-print        { display: none !important; }
  aside, header, footer { display: none !important; }
  main             { margin: 0 !important; }
}
</style>
