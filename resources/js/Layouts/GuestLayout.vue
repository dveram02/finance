<script setup>
import { onMounted } from 'vue';
import { Link } from '@inertiajs/vue3';
import { useDarkMode } from '@/composables/useDarkMode';

const { init } = useDarkMode();

onMounted(() => {
  // Initialise dark mode for auth pages (Login, 2FA, etc.) which use this
  // layout instead of AppLayout. The inline script in app.blade.php prevents
  // the initial FOUC; init() wires up the reactive ref and OS-change listener.
  init();
});
</script>

<template>
  <div class="flex min-h-screen flex-col items-center bg-surface-3 pt-6 sm:justify-center sm:pt-0 transition-colors duration-300">
    <div class="mt-6 w-full overflow-hidden bg-surface px-6 py-4 shadow-md sm:max-w-md sm:rounded-lg border border-line">
      <slot />
    </div>
  </div>
</template>
