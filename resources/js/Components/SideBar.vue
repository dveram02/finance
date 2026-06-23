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
    title: 'Finance',
    items: [
      { name: 'Budget Allocations', icon: 'fas fa-coins', routeName: 'budget-allocations.index', routeParams: {}, activeWhen: { any: ['budget-allocations.*'] } },
      { name: 'Monthly Expenditure', icon: 'fas fa-chart-line', routeName: 'monthly-expenditure.index', routeParams: {}, activeWhen: { any: ['monthly-expenditure.*'] } },
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
.sidebar-nav::-webkit-scrollbar       { width: 4px; }
.sidebar-nav::-webkit-scrollbar-track { background: transparent; }
.sidebar-nav::-webkit-scrollbar-thumb { background: rgba(148, 163, 184, 0.25); border-radius: 2px; }
.sidebar-nav::-webkit-scrollbar-thumb:hover { background: rgba(148, 163, 184, 0.4); }

.signout-btn {
  color: rgb(var(--color-tx-muted));
  border-color: transparent;
  transition: all 0.2s ease;
}
.signout-btn:hover {
  background: rgba(220, 38, 38, 0.07);
  color: #dc2626;
  border-color: rgba(220, 38, 38, 0.2);
}
:global(.dark) .signout-btn:hover {
  background: rgba(220, 38, 38, 0.1);
  color: #f87171;
  border-color: rgba(220, 38, 38, 0.18);
}
</style>

<template>
  <aside
    :class="[
      'fixed inset-y-0 left-0 z-50 flex flex-col transition-all duration-300 transform',
      'md:translate-x-0',
      mobileOpen ? 'translate-x-0' : '-translate-x-full',
      'w-72',
      'bg-white/82 dark:bg-[#07111f]/86 border-r border-white/70 dark:border-white/10 shadow-xl shadow-slate-950/8 backdrop-blur-xl',
    ]"
  >
    <!-- Logo / header -->
    <div class="relative px-5 py-5 border-b border-white/60 dark:border-white/10">
      <div class="pointer-events-none absolute inset-0 bg-gradient-to-br from-cyan-500/8 via-transparent to-amber-500/10 dark:from-cyan-300/10 dark:to-amber-300/8"></div>
      <div class="relative flex items-center justify-between">
        <div class="flex items-center space-x-3">
          <img
            :src="isDark ? '/images/logo_white.png' : '/images/logo.png'"
            alt="SWRHA Logo"
            class="h-12 w-auto flex-shrink-0 object-contain"
          />
          <div class="flex flex-col min-w-0">
            <h2 class="font-bold text-tx-primary text-base tracking-tight leading-tight truncate">{{ page.props.appName }}</h2>
            <p class="text-xs text-tx-muted font-medium truncate">{{ appTagline }}</p>
          </div>
        </div>

        <!-- Mobile close -->
        <button
          @click="$emit('close-mobile')"
          class="md:hidden p-2 rounded-lg text-tx-muted hover:bg-surface-3 hover:text-tx-primary transition-all duration-200"
          aria-label="Close menu"
        >
          <i class="fas fa-times text-base"></i>
        </button>
      </div>
      <!-- Amber accent bar -->
      <div class="absolute bottom-0 left-0 right-0 h-px bg-gradient-to-r from-cyan-500/50 via-amber-400/50 to-transparent"></div>
    </div>

    <!-- Navigation -->
    <nav class="flex-1 overflow-y-auto py-4 px-3 sidebar-nav">
      <template v-for="section in visibleSections" :key="section.title">
        <div class="mb-5" v-if="sectionVisible(section)">
          <h3 class="px-3 mb-2 text-[10px] font-semibold text-tx-subtle uppercase tracking-widest">
            {{ section.title }}
          </h3>

          <ul class="space-y-0.5">
            <li v-for="item in visibleItems(section.items)" :key="item.name">

              <!-- Group with children -->
              <div v-if="item.children?.length">
                <button
                  v-if="(!item.can || canAny(item.can)) && (!item.role || item.role.some(isRole))"
                  @click="toggleDropdown(item)"
                  class="group w-full flex items-center justify-between px-3 py-2.5 text-sm font-medium rounded-lg transition-all duration-200 relative"
                  :class="
                    isChildActive(item) || item.open
                      ? 'bg-cyan-50 text-cyan-800 dark:bg-cyan-300/10 dark:text-cyan-200'
                      : 'text-tx-body hover:bg-surface-3 hover:text-tx-primary'
                  "
                >
                  <div v-if="isChildActive(item) || item.open" class="absolute left-0 inset-y-1.5 w-0.5 bg-gradient-to-b from-cyan-500 to-amber-500 rounded-r-sm"></div>

                  <div class="flex items-center space-x-3 pl-1">
                    <i :class="`${item.icon} w-4 text-center text-sm`"></i>
                    <span>{{ item.name }}</span>
                  </div>
                  <div class="flex items-center space-x-2">
                    <span v-if="item.badge" class="px-2 py-0.5 text-xs font-bold rounded-full bg-red-500 text-white">
                      {{ item.badge }}
                    </span>
                    <i class="fas fa-chevron-down text-xs transition-transform duration-300 opacity-60"
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
                  <ul v-if="item.open || isChildActive(item)" class="ml-5 mt-1 space-y-0.5 pl-3 border-l-2 border-line">
                    <li v-for="c in visibleChildren(item.children)" :key="c.name">
                      <Link
                        :href="route(c.routeName, c.routeParams)"
                        class="group block px-3 py-2 text-sm font-medium rounded-lg transition-all duration-200 relative"
                        :class="
                          childActive(c)
                            ? 'bg-cyan-50 text-cyan-800 font-semibold dark:bg-cyan-300/10 dark:text-cyan-200'
                            : 'text-tx-muted hover:text-tx-primary hover:bg-surface-2'
                        "
                        @click="
                          if (!hasZiggy()) $emit('activate', c.name);
                          $emit('close-mobile');
                        "
                      >
                        <span class="relative z-10">{{ c.name }}</span>
                        <div v-if="childActive(c)" class="absolute left-0 inset-y-1.5 w-0.5 bg-gradient-to-b from-cyan-500 to-amber-500 rounded-r-full"></div>
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
                      ? 'bg-cyan-50 text-cyan-800 dark:bg-cyan-300/10 dark:text-cyan-200'
                      : 'text-tx-body hover:bg-surface-3 hover:text-tx-primary'
                  "
                  @click="
                    if (!hasZiggy()) $emit('activate', item.name);
                    $emit('close-mobile');
                  "
                >
                  <div v-if="itemActive(item)" class="absolute left-0 inset-y-1.5 w-0.5 bg-gradient-to-b from-cyan-500 to-amber-500 rounded-r-sm"></div>

                  <div class="flex items-center space-x-3 pl-1">
                    <i :class="`${item.icon} w-4 text-center text-sm`"></i>
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
      <div class="flex items-center space-x-3 mb-3 p-2.5 rounded-lg bg-surface-2 hover:bg-surface-3 transition-colors duration-200">
        <div class="relative flex-shrink-0">
          <div class="w-9 h-9 rounded-full flex items-center justify-center font-bold text-xs text-white shadow-md bg-gradient-to-br from-amber-500 to-amber-700">
            {{ initials }}
          </div>
          <div class="absolute -bottom-0.5 -right-0.5 w-2.5 h-2.5 bg-emerald-500 rounded-full border-2 border-surface"></div>
        </div>
        <div class="flex-1 min-w-0">
          <p class="text-sm font-semibold text-tx-primary truncate">{{ props.auth.user.name }}</p>
          <p class="text-xs text-tx-muted truncate">{{ props.auth.user.username }}</p>
        </div>
      </div>

      <!-- Sign out -->
      <Link
        :href="route('logout')"
        method="post"
        as="button"
        class="signout-btn group flex items-center w-full px-3 py-2.5 text-sm font-medium rounded-lg border"
      >
        <i class="fas fa-sign-out-alt w-4 text-center text-sm transition-transform duration-200 group-hover:translate-x-0.5"></i>
        <span class="ml-3">Sign Out</span>
      </Link>
    </div>
  </aside>
</template>
