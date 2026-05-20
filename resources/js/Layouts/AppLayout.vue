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
  <div class="flex flex-col min-h-screen bg-surface-2 transition-colors duration-300">

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
    <div class="flex flex-col flex-1 md:ml-72 overflow-hidden transition-all duration-300">

      <!-- Header -->
      <HeaderBar
        :model="model"
        @toggle-mobile="toggleMobile"
        :auth="auth"
        :is-loading="isLoading"
      />

      <!-- Main content -->
      <main class="flex-1 overflow-y-auto">
        <div class="px-4 sm:px-6 py-4 sm:py-6 animate-fade-in">

          <!-- Breadcrumb -->
          <nav class="mb-4 flex items-center space-x-2 text-sm text-tx-muted">
            <a href="/" class="hover:text-blue-600 dark:hover:text-blue-400 transition-colors duration-200">
              <i class="fas fa-home"></i>
            </a>
            <i class="fas fa-chevron-right text-xs text-tx-subtle"></i>
            <span class="font-medium text-tx-primary">{{ $page.component.replace(/\//g, ' / ') }}</span>
          </nav>

          <!-- Page content -->
          <div class="space-y-6">
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
      class="fixed bottom-8 right-8 w-12 h-12 bg-gradient-to-br from-blue-600 to-purple-600 text-white
             rounded-full shadow-lg hover:shadow-xl hover:scale-110 transition-all duration-300
             flex items-center justify-center z-40
             opacity-0 pointer-events-none md:opacity-100 md:pointer-events-auto"
      aria-label="Back to top"
    >
      <i class="fas fa-arrow-up"></i>
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
