<script setup>
import { computed } from 'vue'

const props = defineProps({
  flash: { type: Object, default: () => ({}) }
})

const hasFlash = computed(() =>
  props.flash?.success || props.flash?.error || props.flash?.message || props.flash?.warning
)
</script>

<template>
  <div v-if="hasFlash" class="space-y-3">

    <!-- Success -->
    <div v-if="flash.success"
         class="p-4 bg-green-50 border border-green-200 text-green-800 rounded-lg flex items-center gap-2
                dark:bg-green-900/20 dark:border-green-800 dark:text-green-400">
      <svg class="w-5 h-5 flex-shrink-0" fill="currentColor" viewBox="0 0 20 20">
        <path fill-rule="evenodd"
              d="M10 18a8 8 0 100-16 8 8 0 000 16zm3.707-9.293a1 1 0 00-1.414-1.414L9 10.586 7.707 9.293a1 1 0 00-1.414 1.414l2 2a1 1 0 001.414 0l4-4z"
              clip-rule="evenodd"/>
      </svg>
      <span>{{ flash.success }}</span>
    </div>

    <!-- Error -->
    <div v-if="flash.error"
         class="p-4 bg-red-50 border border-red-200 text-red-800 rounded-lg flex items-center gap-2
                dark:bg-red-900/20 dark:border-red-800 dark:text-red-400">
      <svg class="w-5 h-5 flex-shrink-0" fill="currentColor" viewBox="0 0 20 20">
        <path fill-rule="evenodd"
              d="M10 18a8 8 0 100-16 8 8 0 000 16zM8.707 7.293a1 1 0 00-1.414 1.414L8.586 10l-1.293 1.293a1 1 0 101.414 1.414L10 11.414l1.293 1.293a1 1 0 001.414-1.414L11.414 10l1.293-1.293a1 1 0 00-1.414-1.414L10 8.586 8.707 7.293z"
              clip-rule="evenodd"/>
      </svg>
      <span>{{ flash.error }}</span>
    </div>

    <!-- Warning -->
    <div v-if="flash.warning"
         class="p-4 bg-amber-50 border border-amber-200 text-amber-800 rounded-lg flex items-center gap-2
                dark:bg-amber-900/20 dark:border-amber-800 dark:text-amber-400">
      <svg class="w-5 h-5 flex-shrink-0" fill="currentColor" viewBox="0 0 20 20">
        <path fill-rule="evenodd"
              d="M8.257 3.099c.765-1.36 2.722-1.36 3.486 0l5.58 9.92c.75 1.334-.213 2.98-1.742 2.98H4.42c-1.53 0-2.493-1.646-1.743-2.98l5.58-9.92zM11 13a1 1 0 11-2 0 1 1 0 012 0zm-1-8a1 1 0 00-1 1v3a1 1 0 002 0V6a1 1 0 00-1-1z"
              clip-rule="evenodd"/>
      </svg>
      <span>{{ flash.warning }}</span>
    </div>

    <!-- Info -->
    <div v-if="flash.message"
         class="p-4 bg-blue-50 border border-blue-200 text-blue-800 rounded-lg flex items-center gap-2
                dark:bg-blue-900/20 dark:border-blue-800 dark:text-blue-400">
      <svg class="w-5 h-5 flex-shrink-0" fill="currentColor" viewBox="0 0 20 20">
        <path fill-rule="evenodd"
              d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-7-4a1 1 0 11-2 0 1 1 0 012 0zM9 9a1 1 0 000 2v3a1 1 0 001 1h1a1 1 0 100-2v-3a1 1 0 00-1-1H9z"
              clip-rule="evenodd"/>
      </svg>
      <span>{{ flash.message }}</span>
    </div>

  </div>
</template>
