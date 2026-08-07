<script setup>
import { usePage } from '@inertiajs/vue3';
import { ref } from 'vue';
import PolicyModals from './PolicyModals.vue';

const currentYear = ref(new Date().getFullYear());
const showPrivacyModal = ref(false);
const showTermsModal = ref(false);

const page = usePage();
const version = page.props.appVersion || '';

const openSupport = () => {
  window.location.href = 'mailto:technical.support@swrha.co.tt?subject=Finance Automation System Support Request';
};
</script>

<template>
  <footer class="bg-surface/80 backdrop-blur-sm border-t border-line/50 mt-auto transition-colors duration-300">
    <div class="max-w-full px-4 sm:px-7 py-2.5">
      <!-- Single row on wide screens, stacked and centred on mobile -->
      <div class="flex flex-col items-center gap-2 text-center text-[11px] sm:text-xs lg:flex-row lg:items-center lg:justify-between lg:gap-4 lg:text-left">
        <!-- Left: Copyright -->
        <div class="text-tx-muted lg:flex-shrink-0">
          © <span id="copyright-year">{{ currentYear }}</span> SWRHA. All Rights Reserved.
        </div>

        <!-- Center: Quick links with icons -->
        <div class="flex flex-wrap items-center justify-center gap-x-3 gap-y-1 sm:gap-x-4 text-tx-subtle">
          <button
            @click="showPrivacyModal = true"
            class="hover:text-blue-600 transition-colors duration-200 flex items-center gap-1 focus:outline-none focus:text-blue-600"
          >
            <i class="fas fa-shield-alt text-xs"></i>
            <span>Privacy</span>
          </button>
          <span class="text-tx-subtle">•</span>
          <button
            @click="showTermsModal = true"
            class="hover:text-blue-600 transition-colors duration-200 flex items-center gap-1 focus:outline-none focus:text-blue-600"
          >
            <i class="fas fa-file-contract text-xs"></i>
            <span>Terms</span>
          </button>
          <span class="text-tx-subtle">•</span>
          <button
            @click="openSupport"
            class="hover:text-blue-600 transition-colors duration-200 flex items-center gap-1 focus:outline-none focus:text-blue-600"
          >
            <i class="fas fa-life-ring text-xs"></i>
            <span>Support</span>
          </button>
        </div>

        <!-- Right: Version, status & collaboration -->
        <div class="flex flex-wrap items-center justify-center gap-x-3 gap-y-1.5 sm:gap-x-4 lg:flex-nowrap lg:flex-shrink-0">
          <span class="flex items-center gap-1.5 text-tx-subtle">
            <i class="fas fa-code text-blue-500"></i>
            <span>v{{ version }}</span>
          </span>
          <div class="flex items-center gap-1.5 px-2.5 py-1 bg-green-50 rounded-full border border-green-200 dark:bg-green-900/20 dark:border-green-800">
            <div class="w-1.5 h-1.5 bg-green-500 rounded-full animate-pulse"></div>
            <i class="fas fa-server text-green-600 dark:text-green-400 text-xs"></i>
            <span class="font-medium text-green-700 dark:text-green-400">Online</span>
          </div>
          <span class="flex items-center gap-1.5 text-tx-subtle lg:whitespace-nowrap">
            <i class="fas fa-handshake text-teal-500"></i>
            <span>In Collaboration with <span class="font-medium text-teal-600 dark:text-teal-400">Finance and ICT</span></span>
          </span>
        </div>
      </div>
    </div>

    <!-- Minimal gradient accent -->
    <div class="h-0.5 bg-gradient-to-r from-blue-500 via-purple-500 to-pink-500"></div>
  </footer>

  <PolicyModals v-model:privacy="showPrivacyModal" v-model:terms="showTermsModal" />
</template>

<style scoped>
/* Smooth link transitions */
button {
  position: relative;
}

button::after {
  content: '';
  position: absolute;
  bottom: -2px;
  left: 0;
  width: 0;
  height: 1px;
  background: linear-gradient(to right, #3b82f6, #a855f7);
  transition: width 0.3s ease;
}

button:hover::after {
  width: 100%;
}

@keyframes pulse {
  0%, 100% {
    opacity: 1;
  }
  50% {
    opacity: 0.5;
  }
}

.animate-pulse {
  animation: pulse 2s cubic-bezier(0.4, 0, 0.6, 1) infinite;
}
</style>
