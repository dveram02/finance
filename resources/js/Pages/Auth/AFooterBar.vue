<script setup>
import { usePage } from '@inertiajs/vue3'
const page = usePage()
</script>

<template>
    <footer class="bg-surface border-t border-line mt-auto ">
      <div class="max-w-full px-6 py-4 flex flex-col sm:flex-row sm:items-center sm:justify-between">
        <div class="text-sm text-tx-muted">© 2025 {{ page.props.appName }}. All Rights Reserved.</div>
        <div class="flex items-center space-x-4 mt-2 sm:mt-0">
          <button class="text-sm text-tx-muted hover:text-blue-600">Privacy Policy</button>
          <button class="text-sm text-tx-muted hover:text-blue-600">Terms of Service</button>
          <button class="text-sm text-tx-muted hover:text-blue-600">Support</button>
        </div>
      </div>
    </footer>
</template>
