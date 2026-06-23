<template>
  <aside
    :class="[
      'fixed inset-y-0 left-0 z-50 flex flex-col bg-surface border-r border-line shadow-lg transition-transform duration-300 transform',
      'md:translate-x-0',
      mobileOpen ? 'translate-x-0' : '-translate-x-full',
      'w-72'
    ]"
  >
    <!-- Logo/Header -->
    <div class="flex items-center p-6 border-b border-line">
      <div class="flex items-center space-x-3">
        <div class="w-20 h-20 rounded-lg flex items-center justify-center">
            <img :src="isDark ? '/images/logo_white.png' : '/images/logo.png'" alt="SWRHA Logo"></img>
        </div>
        <div class="flex flex-col">
          <h2 class="font-semibold text-gray-800">{{ page.props.appName }}</h2>
          <p class="text-xs text-tx-muted">Employee Services</p>
        </div>
      </div>
    </div>

    <!-- Navigation -->
    <nav class="flex-1 overflow-y-auto py-6">
      <template v-for="section in sections" :key="section.title">
        <div class="px-6 mb-6">
          <h3 class="text-xs text-tx-subtle uppercase tracking-wider mb-3">
            {{ section.title }}
          </h3>
          <ul class="space-y-2">
            <li v-for="item in section.items" :key="item.name">
              <div v-if="item.children">
                <button
                  @click="toggleDropdown(item)"
                  class="w-full flex items-center justify-between px-3 py-2 text-sm rounded-lg hover:bg-surface-3 transition-colors"
                  :class="{ 'bg-surface-3': isChildActive(item) }"
                >
                  <div class="flex items-center space-x-3">
                    <i :class="`${item.icon} w-5 text-center`"></i>
                    <span>{{ item.name }}</span>
                  </div>
                  <i
                    class="fas fa-chevron-down transition-transform duration-200"
                    :class="{ 'rotate-180': item.open || isChildActive(item) }"
                  ></i>
                </button>

                <ul v-if="item.open || isChildActive(item)" class="ml-8 mt-2 space-y-1">
                  <li v-for="child in item.children" :key="child.name">
                    <Link
                      :href="route(child.routeName, child.routeParams)"
                      class="block px-3 py-2 text-sm rounded-lg hover:bg-surface-3 transition-colors"
                      :class="{ 'bg-surface-3': active === child.name }"
                      @click="$emit('activate', child.name)"
                    >
                      {{ child.name }}
                    </Link>
                  </li>
                </ul>
              </div>

              <div v-else>
                <Link
                  :href="route(item.routeName, item.routeParams)"
                  class="flex items-center px-3 py-2 text-sm rounded-lg hover:bg-surface-3 transition-colors"
                  :class="{ 'bg-surface-3': active === item.name }"
                  @click="$emit('activate', item.name)"
                >
                  <i :class="`${item.icon} w-5 text-center`"></i>
                  <span class="ml-3">{{ item.name }}</span>
                </Link>
              </div>
            </li>
          </ul>
        </div>
      </template>
    </nav>

    <!-- Footer -->
    <div class="p-6 border-t border-line mt-auto">
      <div class="flex items-center space-x-3 mb-4">
        <div class="w-8 h-8 bg-blue-600 rounded-full text-white flex items-center justify-center">
          <i class="fas fa-user"></i>
        </div>
        <div class="truncate">
          <p class="text-sm font-medium text-gray-800 truncate">Admin User</p>
          <p class="text-xs text-tx-muted truncate">admin@company.com</p>
        </div>
      </div>
      <button
        @click="$emit('sign‑out')"
        class="flex items-center w-full px-3 py-2 text-sm rounded-lg hover:bg-surface-3 transition-colors"
      >
        <i class="fas fa-sign-out-alt w-5"></i>
        <span class="ml-3">Sign Out</span>
      </button>
    </div>
  </aside>
</template>

<script setup>
import { reactive } from 'vue'
import { Link, usePage } from '@inertiajs/vue3'
import { useDarkMode } from '@/composables/useDarkMode'

const page = usePage()
const { isDark } = useDarkMode()

const props = defineProps({
  active: String,
  mobileOpen: Boolean
})
const emit = defineEmits(['activate', 'sign‑out'])

const sections = reactive([
  {
    title: 'Dashboard',
    items: [
      { name: 'Overview', icon: 'fas fa-tachometer-alt', routeName: 'example', routeParams: {} },
    //   { name: 'Analytics', icon: 'fas fa-chart-bar', routeName: 'example', routeParams: {} },
    //   { name: 'Reports', icon: 'fas fa-chart-pie', routeName: 'example', routeParams: {} },
    ]
  },
  {
    title: 'Requests',
    items: [
      {
        name: 'Requisitions',
        icon: 'fas fa-clipboard-list',
        children: [
          { name: 'View Requisitions', routeName: 'requisitions.index', routeParams: {} },
        //   { name: 'In Progress', routeName: 'example', routeParams: {} },
        ],
        open: false
      },
      { name: 'Create Requisition', icon: 'fas fa-plus-circle', routeName: 'requisitions.create', routeParams: {} },
    ]
  },
  {
    title: 'Management',
    items: [
      {
        name: 'Users',
        icon: 'fas fa-users',
        children: [
          { name: 'All Users', routeName: 'example', routeParams: {} },
          { name: 'Administrators', routeName: 'example', routeParams: {} },
        ],
        open: false
      },
      { name: 'Inventory', icon: 'fas fa-warehouse', routeName: 'example', routeParams: {} },
    ]
  },
  {
    title: 'System',
    items: [
      {
        name: 'Settings',
        icon: 'fas fa-cog',
        children: [
          { name: 'General', routeName: 'example', routeParams: {} },
          { name: 'Email Notifications', routeName: 'example', routeParams: {} },
          { name: 'Workflow Rules', routeName: 'example', routeParams: {} },
          { name: 'Approval', routeName: 'example', routeParams: {} },
        ],
        open: false
      },
      { name: 'Security', icon: 'fas fa-shield-alt', routeName: 'example', routeParams: {} },
      { name: 'Audit Logs', icon: 'fas fa-history', routeName: 'example', routeParams: {} },
    ]
  }
])

function toggleDropdown(item) {
  item.open = !item.open
}

function isChildActive(item) {
  return item.children?.some(child => child.name === props.active)
}
</script>
