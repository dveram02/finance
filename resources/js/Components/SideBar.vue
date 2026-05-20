<script setup>
import { reactive, computed, onUnmounted } from 'vue'
import { Link, usePage, router } from '@inertiajs/vue3'
import { useDarkMode } from '@/composables/useDarkMode'

const props = defineProps({
  auth: { type: Object, required: true },
  active: String,
  mobileOpen: Boolean,
})

const emit = defineEmits(['activate', 'signout', 'close-mobile'])

// isDark drives the logo swap: logo.png (light) / logo_white.png (dark)
const { isDark } = useDarkMode()

const page = usePage()
const appTagline = import.meta.env.VITE_APP_TAGLINE || ''
const currentUser = computed(() => props.auth?.user ?? null)

/* ---------- auth gates ---------- */
const userPermissions = computed(() => new Set(page.props.auth?.user?.permissions ?? []))
const userRoles       = computed(() => new Set(page.props.auth?.user?.roles ?? []))
const moduleAccess    = computed(() => page.props.moduleAccess ?? {})

const toList = (v) =>
  Array.isArray(v)
    ? v.flatMap(s => String(s).split(',')).map(s => s.trim()).filter(Boolean)
    : String(v ?? '').split(',').map(s => s.trim()).filter(Boolean)

const canAny = (input = []) => toList(input).some(p => userPermissions.value.has(p))
const isRole = (r) => userRoles.value.has(r)
const canAccessModule = (key) => !key || (moduleAccess.value[key] ?? true)

/* ---------- Ziggy helpers ---------- */
const hasZiggy = () => typeof route === 'function' && route().current
const routeMatchesAny = (patterns = []) => hasZiggy() && toList(patterns).some(p => route().current(p))

/* ---------- visibility ---------- */
const itemVisible = (i) => {
  if (!i) return false
  const canGate    = !i.can    || canAny(i.can)
  const roleGate   = !i.role   || i.role.some(isRole)
  const moduleGate = canAccessModule(i.module)
  const selfAllowed = canGate && roleGate && moduleGate
  if (!i.children?.length) return selfAllowed
  if (!selfAllowed) return false
  return i.children.some(child => itemVisible(child))
}

const sectionVisible  = (section) => Array.isArray(section?.items) && section.items.some(item => itemVisible(item))
const visibleSections = computed(() => sections.filter(section => sectionVisible(section)))
const visibleItems    = (items = []) => items.filter(itemVisible)
const childIsVisible  = (c) => (!c?.can || canAny(c.can)) && (!c?.role || c.role?.some(isRole))
const visibleChildren = (children = []) => children.filter(childIsVisible)

/* ---------- active-state ---------- */
const childActive = (c) => {
  if (hasZiggy()) {
    const any    = toList(c?.activeWhen?.any ?? [])
    const except = toList(c?.activeWhen?.except ?? [])
    let on = false
    if (any.length) on = routeMatchesAny(any)
    else if (c.routeName) on = route().current(c.routeName)
    if (on && except.length) on = !routeMatchesAny(except)
    return on
  }
  return props.active === c.name
}

const itemActive = (i) => {
  if (hasZiggy()) {
    const any    = toList(i?.activeWhen?.any ?? [])
    const except = toList(i?.activeWhen?.except ?? [])
    let on = false
    if (any.length) on = routeMatchesAny(any)
    else if (i.routeName) on = route().current(i.routeName)
    if (on && except.length) on = !routeMatchesAny(except)
    return on
  }
  return props.active === i.name
}

const isChildActive = (item) => item.children?.some(childActive)

/* ---------- accordion ---------- */
const forEachGroup    = (cb) => sections.forEach(s => s.items?.forEach(i => { if (i?.children?.length) cb(i) }))
const closeAllGroups  = () => forEachGroup(i => { i.open = false })
const openOnly        = (target) => forEachGroup(i => { i.open = (i === target) })

const toggleDropdown = (item) => {
  if (!item?.children?.length) return
  item.open ? (item.open = false) : openOnly(item)
}

const removeNavigate = router.on('navigate', () => closeAllGroups())
onUnmounted(() => removeNavigate())

/* ---------- menu ---------- */
const sections = reactive([
  {
    title: 'Dashboard',
    items: [
      { name: 'Dashboard', icon: 'fas fa-home', routeName: 'dashboard', routeParams: {}, badge: null, activeWhen: { any: ['dashboard'] } },
    ]
  },
  {
    title: 'Profile',
    items: [
      { name: 'View Profile', icon: 'fa-solid fa-user', routeName: 'profile.view', routeParams: {}, activeWhen: { any: ['profile.*'] } },
    ]
  },
])

function getInitials(fullName) {
  if (!fullName || typeof fullName !== 'string') return 'U';
  const parts = fullName.trim().split(/\s+/).slice(0, 2);
  return parts.map(p => p[0]?.toUpperCase()).join('') || 'U';
}

const initials = computed(() => getInitials(page.props.auth?.user?.name));
</script>

<style scoped>
/* Sidebar scrollbar — light mode */
.scrollbar-thin::-webkit-scrollbar       { width: 6px; }
.scrollbar-thin::-webkit-scrollbar-track { background: transparent; }
.scrollbar-thin::-webkit-scrollbar-thumb { background: rgb(209 213 219); border-radius: 3px; }
.scrollbar-thin::-webkit-scrollbar-thumb:hover { background: rgb(156 163 175); }

/* Dark-mode sidebar scrollbar */
:global(.dark) .scrollbar-thin::-webkit-scrollbar-thumb       { background: rgb(75 85 99); }
:global(.dark) .scrollbar-thin::-webkit-scrollbar-thumb:hover { background: rgb(107 114 128); }
</style>

<template>
  <!-- bg-surface = white (light) / gray-900 (dark)  |  border-line adapts accordingly -->
  <aside
    :class="[
      'fixed inset-y-0 left-0 z-50 flex flex-col transition-all duration-300 transform',
      'md:translate-x-0',
      mobileOpen ? 'translate-x-0' : '-translate-x-full',
      'w-72',
      'bg-surface',
      'border-r border-line shadow-lg',
    ]"
  >
    <!-- Logo / header -->
    <div class="relative p-6 border-b border-line">
      <div class="flex items-center justify-between">
        <div class="flex items-center space-x-3">
          <div class="w-20 h-20 rounded-xl flex items-center justify-center">
            <!-- logo_white.png in dark mode, logo.png in light mode -->
            <img
              :src="isDark ? '/images/logo_white.png' : '/images/logo.png'"
              alt="SWRHA Logo"
              class="w-20 h-20 object-contain"
            />
          </div>
          <div class="flex flex-col">
            <h2 class="font-bold text-tx-primary text-lg tracking-tight">{{ page.props.appName }}</h2>
            <p class="text-xs text-tx-muted font-medium">{{ appTagline }}</p>
          </div>
        </div>

        <!-- Mobile close -->
        <button
          @click="$emit('close-mobile')"
          class="md:hidden p-2 rounded-lg text-tx-muted hover:bg-surface-3 hover:text-tx-primary transition-all duration-200"
          aria-label="Close menu"
        >
          <i class="fas fa-times text-xl"></i>
        </button>
      </div>
      <!-- Decorative gradient bar -->
      <div class="absolute bottom-0 left-0 right-0 h-0.5 bg-gradient-to-r from-blue-500 via-purple-500 to-pink-500"></div>
    </div>

    <!-- Navigation -->
    <nav class="flex-1 overflow-y-auto py-4 px-3 scrollbar-thin">
      <template v-for="section in visibleSections" :key="section.title">
        <div class="mb-6" v-if="sectionVisible(section)">
          <h3 class="px-3 mb-3 text-xs font-semibold text-tx-subtle uppercase tracking-wider">
            {{ section.title }}
          </h3>

          <ul class="space-y-1">
            <li v-for="item in visibleItems(section.items)" :key="item.name">

              <!-- Group with children -->
              <div v-if="item.children?.length">
                <button
                  v-if="(!item.can || canAny(item.can)) && (!item.role || item.role.some(isRole))"
                  @click="toggleDropdown(item)"
                  class="group w-full flex items-center justify-between px-3 py-2.5 text-sm font-medium rounded-lg transition-all duration-200"
                  :class="
                    isChildActive(item) || item.open
                      ? 'bg-gradient-to-r from-blue-600 to-purple-600 text-white shadow-md'
                      : 'text-tx-body hover:bg-surface-3 hover:text-tx-primary'
                  "
                >
                  <div class="flex items-center space-x-3">
                    <i :class="`${item.icon} w-5 text-center transition-transform duration-200`"
                       :style="isChildActive(item) || item.open ? 'transform: scale(1.1)' : ''"></i>
                    <span>{{ item.name }}</span>
                  </div>
                  <div class="flex items-center space-x-2">
                    <span v-if="item.badge" class="px-2 py-0.5 text-xs font-bold rounded-full bg-red-500 text-white">
                      {{ item.badge }}
                    </span>
                    <i class="fas fa-chevron-down text-xs transition-transform duration-300"
                       :class="{ 'rotate-180': item.open || isChildActive(item) }" />
                  </div>
                </button>

                <transition
                  enter-active-class="transition-all duration-300 ease-out"
                  enter-from-class="opacity-0 -translate-y-2"
                  enter-to-class="opacity-100 translate-y-0"
                  leave-active-class="transition-all duration-200 ease-in"
                  leave-from-class="opacity-100 translate-y-0"
                  leave-to-class="opacity-0 -translate-y-2"
                >
                  <!-- border-line adapts to dark mode via CSS variable -->
                  <ul v-if="item.open || isChildActive(item)" class="ml-6 mt-1 space-y-1 border-l-2 border-line pl-3">
                    <li v-for="c in visibleChildren(item.children)" :key="c.name">
                      <Link
                        :href="route(c.routeName, c.routeParams)"
                        class="group block px-3 py-2 text-sm font-medium rounded-lg transition-all duration-200 relative"
                        :class="
                          childActive(c)
                            ? 'text-blue-600 bg-blue-50 font-semibold dark:text-blue-400 dark:bg-blue-900/20'
                            : 'text-tx-muted hover:text-tx-primary hover:bg-surface-2'
                        "
                        @click="
                          if (!hasZiggy()) $emit('activate', c.name);
                          $emit('close-mobile');
                        "
                      >
                        <span class="relative z-10">{{ c.name }}</span>
                        <!-- Active left-border accent (gradient) -->
                        <div v-if="childActive(c)" class="absolute left-0 top-1/2 -translate-y-1/2 w-1 h-8 bg-gradient-to-b from-blue-500 to-purple-500 rounded-r-full"></div>
                      </Link>
                    </li>
                  </ul>
                </transition>
              </div>

              <!-- Flat item -->
              <div v-else-if="(!item.can || canAny(item.can)) && (!item.role || item.role.some(isRole))">
                <Link
                  :href="route(item.routeName, item.routeParams)"
                  class="group flex items-center justify-between px-3 py-2.5 text-sm font-medium rounded-lg transition-all duration-200 relative"
                  :class="
                    itemActive(item)
                      ? 'bg-gradient-to-r from-blue-600 to-purple-600 text-white shadow-md'
                      : 'text-tx-body hover:bg-surface-3 hover:text-tx-primary'
                  "
                  @click="
                    if (!hasZiggy()) $emit('activate', item.name);
                    $emit('close-mobile');
                  "
                >
                  <div class="flex items-center space-x-3">
                    <i :class="`${item.icon} w-5 text-center transition-transform duration-200`"
                       :style="itemActive(item) ? 'transform: scale(1.1)' : ''"></i>
                    <span>{{ item.name }}</span>
                  </div>
                  <span v-if="item.badge" class="px-2 py-0.5 text-xs font-bold rounded-full bg-red-500 text-white">
                    {{ item.badge }}
                  </span>
                </Link>
              </div>
            </li>
          </ul>
        </div>
      </template>
    </nav>

    <!-- Footer: user info + sign out -->
    <div class="p-4 border-t border-line">
      <!-- User info card -->
      <div class="flex items-center space-x-3 mb-3 p-2 rounded-lg bg-surface-2 hover:bg-surface-3 transition-colors duration-200">
        <div class="relative">
          <div class="w-10 h-10 bg-gradient-to-br from-blue-500 to-purple-600 rounded-full text-white flex items-center justify-center font-bold text-sm shadow-lg">
            {{ initials }}
          </div>
          <!-- Online dot — border-surface so it blends with the card background -->
          <div class="absolute -bottom-0.5 -right-0.5 w-3 h-3 bg-green-500 rounded-full border-2 border-surface"></div>
        </div>
        <div class="flex-1 min-w-0">
          <p class="text-sm font-semibold text-tx-primary truncate">{{ props.auth.user.name }}</p>
          <p class="text-xs text-tx-muted truncate">{{ props.auth.user.email }}</p>
        </div>
      </div>

      <!-- Sign out -->
      <Link
        :href="route('logout')"
        method="post"
        as="button"
        class="group flex items-center w-full px-3 py-2.5 text-sm font-medium rounded-lg transition-all duration-200
               text-tx-body hover:bg-red-50 hover:text-red-600 dark:hover:bg-red-900/20 dark:hover:text-red-400
               border border-transparent hover:border-red-200 dark:hover:border-red-800"
      >
        <i class="fas fa-sign-out-alt w-5 transition-transform duration-200 group-hover:translate-x-1"></i>
        <span class="ml-3">Sign Out</span>
      </Link>
    </div>
  </aside>
</template>
