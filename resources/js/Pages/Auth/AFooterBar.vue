<script setup>
import { usePage } from '@inertiajs/vue3'
import { ref } from 'vue'
// DISABLED 2026-10-03 — the Privacy and Terms entry points were switched off in
// BOTH footers (here and Components/FooterBar.vue). The documents themselves are
// untouched: Components/Legal/{LegalModal,PrivacyPolicyContent,TermsContent}.vue
// and resources/js/legal.js all remain. To re-enable, uncomment this import, the
// two refs below, the two buttons in the template, and the PolicyModals mount.
// import PolicyModals from '@/Components/PolicyModals.vue'

const page = usePage()

const currentYear = ref(new Date().getFullYear())
// const showPrivacyModal = ref(false)
// const showTermsModal = ref(false)

const openSupport = () => {
  window.location.href = 'mailto:technical.support@swrha.co.tt?subject=Finance Automation System Support Request'
}
</script>

<template>
    <footer class="bg-surface border-t border-line mt-auto ">
      <div class="max-w-full px-6 py-4 flex flex-col sm:flex-row sm:items-center sm:justify-between">
        <div class="text-sm text-tx-muted">© {{ currentYear }} {{ page.props.appName }}. All Rights Reserved.</div>
        <div class="flex items-center space-x-4 mt-2 sm:mt-0">
          <!-- DISABLED 2026-10-03 — Privacy and Terms on the sign-in page.
          <button @click="showPrivacyModal = true" class="text-sm text-tx-muted hover:text-blue-600">Privacy Policy</button>
          <button @click="showTermsModal = true" class="text-sm text-tx-muted hover:text-blue-600">Terms and Conditions</button>
          -->
          <button @click="openSupport" class="text-sm text-tx-muted hover:text-blue-600">Support</button>
        </div>
      </div>
    </footer>

    <!-- DISABLED 2026-10-03 — see the note in <script setup>.
    <PolicyModals v-model:privacy="showPrivacyModal" v-model:terms="showTermsModal" />
    -->
</template>
