<template>
  <div class="flex flex-col min-h-screen bg-surface-2">
    <!-- Sidebar -->
    <SideBar
      :mobile-open="mobileOpen"
      :active="active"
      @activate="active = $event"
      @sign-out="signOut"
      @close-mobile="mobileOpen = false"
    />

    <!-- Mobile overlay -->
    <div
      v-if="mobileOpen"
      class="fixed inset-0 bg-black bg-opacity-50 z-40 md:hidden"
      @click="toggleMobile"
    ></div>

    <!-- Main layout container shifted right on md+ screens -->
    <div class="flex flex-col flex-1 md:ml-72 overflow-hidden">
      <!-- Header -->
      <HeaderBar :model="model" @toggle-mobile="toggleMobile" />

      <!-- Main content scrollable -->
      <main class="flex-1 overflow-y-auto px-6 py-6">
        <slot />
      </main>

      <!-- Footer -->
      <FooterBar />
    </div>
  </div>
</template>

<script setup>
import { ref, reactive } from 'vue'
import HeaderBar from './AHeaderBar.vue'
import SideBar from './ASideBar.vue'
import FooterBar from './AFooterBar.vue'


const mobileOpen = ref(false)
const active = ref('Overview')
const model = reactive({
  range: '30',
  department: 'all',
  lastUpdated: new Date().toLocaleString(),
  countdown: 23
})

function toggleMobile() {
  mobileOpen.value = !mobileOpen.value
}
function signOut() {
  // sign-out logic
}

setInterval(() => {
  model.lastUpdated = new Date().toLocaleString()
}, 60000)
</script>
