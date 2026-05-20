<script setup>
import { computed, ref, onMounted, onUnmounted } from 'vue';
import { router, usePage } from '@inertiajs/vue3';
import axios from 'axios';
import { useDarkMode } from '@/composables/useDarkMode';

const props = defineProps({
  auth:      { type: Object,  required: true  },
  model:     { type: Object,  required: false },
  isLoading: { type: Boolean, default: false  },
});

defineEmits(['toggle-mobile']);

// auth is an object ref — property access in computeds stays reactive via Vue's proxy
const auth = props.auth;

const page = usePage();

// Dark mode — isDark drives the pill toggle UI; toggle() flips the mode
const { isDark, toggle } = useDarkMode();

function getFirstName(fullName) {
  if (!fullName || typeof fullName !== 'string') return 'User';
  const trimmed = fullName.trim();
  if (!trimmed) return 'User';
  const parts = trimmed.split(/\s+/);
  const fn = parts[0];
  if (!fn) return 'User';
  return fn;
}

const firstName = computed(() => getFirstName(auth.user?.name));

const greeting = computed(() => {
  const hour = new Date().getHours();
  if (hour < 12) return 'Good morning';
  if (hour < 18) return 'Good afternoon';
  return 'Good evening';
});

const greetingIcon = computed(() => {
  const hour = new Date().getHours();
  if (hour < 12) return 'fa-sun text-yellow-500';
  if (hour < 18) return 'fa-cloud-sun text-orange-500';
  return 'fa-moon text-indigo-400';
});

// ── Role display ──────────────────────────────────────────────────────────────
const roleName = computed(() => {
  const r = auth.user?.roles?.[0];
  return (typeof r === 'string' ? r : r?.name) ?? 'General User';
});

const ROLE_CONFIGS = {
  'Admin':                    { icon: 'fa-shield-alt',   classes: 'bg-rose-100    text-rose-800    dark:bg-rose-900/30    dark:text-rose-400'    },
  'HOD':                      { icon: 'fa-user-tie',     classes: 'bg-violet-100  text-violet-800  dark:bg-violet-900/30  dark:text-violet-400'  },
  'Clerk':                    { icon: 'fa-file-alt',     classes: 'bg-blue-100    text-blue-800    dark:bg-blue-900/30    dark:text-blue-400'    },
  'Stores Clerk':             { icon: 'fa-store',        classes: 'bg-amber-100   text-amber-800   dark:bg-amber-900/30   dark:text-amber-400'   },
  'Inventory Clerk':          { icon: 'fa-boxes',        classes: 'bg-cyan-100    text-cyan-800    dark:bg-cyan-900/30    dark:text-cyan-400'    },
  'Inventory Manager':        { icon: 'fa-chart-bar',    classes: 'bg-indigo-100  text-indigo-800  dark:bg-indigo-900/30  dark:text-indigo-400'  },
  'Senior Inventory Officer': { icon: 'fa-star',         classes: 'bg-purple-100  text-purple-800  dark:bg-purple-900/30  dark:text-purple-400'  },
  'Stores Attendant':         { icon: 'fa-eye',          classes: 'bg-emerald-100 text-emerald-800 dark:bg-emerald-900/30 dark:text-emerald-400' },
  'General User':             { icon: 'fa-user',         classes: 'bg-slate-100   text-slate-700   dark:bg-slate-800      dark:text-slate-400'   },
};

const roleConfig = computed(() => ROLE_CONFIGS[roleName.value] ?? ROLE_CONFIGS['General User']);


// ── Notifications ────────────────────────────────────────────────────────────
const notifications          = ref([]);
const unreadCount            = ref(0);
const showNotifications      = ref(false);
const notificationsRef       = ref(null);
const isLoadingNotifications = ref(false);

const fetchNotifications = async () => {
  try {
    isLoadingNotifications.value = true;
    const response = await axios.get('/notifications');
    notifications.value = response.data.notifications;
    unreadCount.value   = response.data.unread_count;
  } catch (error) {
    console.error('Error fetching notifications:', error);
  } finally {
    isLoadingNotifications.value = false;
  }
};

const markAsRead = async (notificationId) => {
  try {
    await axios.patch(`/notifications/${notificationId}/read`);
    const n = notifications.value.find(n => n.id === notificationId);
    if (n && !n.read_at) {
      n.read_at = new Date().toISOString();
      unreadCount.value = Math.max(0, unreadCount.value - 1);
    }
  } catch (error) {
    console.error('Error marking notification as read:', error);
  }
};

const markAllAsRead = async () => {
  try {
    await axios.patch('/notifications/read-all');
    notifications.value.forEach(n => { if (!n.read_at) n.read_at = new Date().toISOString(); });
    unreadCount.value = 0;
  } catch (error) {
    console.error('Error marking all as read:', error);
  }
};

const handleNotificationClick = async (notification) => {
  if (!notification.read_at) await markAsRead(notification.id);
  if (notification.data.action_url) {
    showNotifications.value = false;
    router.visit(notification.data.action_url);
  }
};

const deleteNotification = async (notificationId, event) => {
  event.stopPropagation();
  try {
    await axios.delete(`/notifications/${notificationId}`);
    const index = notifications.value.findIndex(n => n.id === notificationId);
    if (index !== -1) {
      if (!notifications.value[index].read_at)
        unreadCount.value = Math.max(0, unreadCount.value - 1);
      notifications.value.splice(index, 1);
    }
  } catch (error) {
    console.error('Error deleting notification:', error);
  }
};

// ── Click-outside (notifications panel) ──────────────────────────────────────
const handleClickOutside = (event) => {
  if (notificationsRef.value && !notificationsRef.value.contains(event.target))
    showNotifications.value = false;
};

let notificationRefreshInterval;
onMounted(() => {
  fetchNotifications();
  document.addEventListener('click', handleClickOutside);
  notificationRefreshInterval = setInterval(fetchNotifications, 30000);
});
onUnmounted(() => {
  document.removeEventListener('click', handleClickOutside);
  if (notificationRefreshInterval) clearInterval(notificationRefreshInterval);
});

// Status badge colours — inline dark: variants for in-notification chips
const getStatusBadgeColor = (status) => {
  const s = status?.toLowerCase() || '';
  if (['approved', 'fulfilling', 'closed'].includes(s))
    return 'bg-green-100 text-green-800 dark:bg-green-900/30 dark:text-green-400';
  if (['rejected', 'cancelled'].includes(s))
    return 'bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-400';
  if (s === 'submitted')
    return 'bg-blue-100 text-blue-800 dark:bg-blue-900/30 dark:text-blue-400';
  return 'bg-surface-3 text-tx-body';
};
</script>

<template>
  <!-- bg-surface/80 = white/80 light, gray-900/80 dark via CSS variable -->
  <header class="sticky top-0 bg-surface/80 backdrop-blur-md shadow-sm border-b border-line/60 z-30 transition-all duration-300 w-full">
    <div class="px-4 sm:px-6 py-3 sm:py-4 max-w-full">

      <!-- Top row: greeting + actions -->
      <div class="flex flex-col md:flex-row md:justify-between md:items-start gap-3 sm:gap-4">

        <!-- Left: mobile toggle + greeting -->
        <div class="flex items-center space-x-3 sm:space-x-4">
          <!-- Mobile hamburger -->
          <button
            class="p-2 rounded-xl text-tx-body hover:bg-surface-3 active:bg-surface-4 md:hidden transition-all duration-200 touch-manipulation"
            @click="$emit('toggle-mobile')"
            aria-label="Toggle menu"
          >
            <i class="fas fa-bars text-lg"></i>
          </button>

          <!-- Greeting -->
          <div class="flex items-center space-x-3">
            <div class="hidden sm:flex w-10 h-10 bg-gradient-to-br from-blue-500 to-purple-600 rounded-xl items-center justify-center text-white shadow-lg">
              <i :class="`fas ${greetingIcon} text-lg`"></i>
            </div>
            <div class="flex flex-col">
              <h1 class="text-xl sm:text-2xl font-bold text-tx-primary tracking-tight">
                {{ greeting }}, <span class="bg-gradient-to-r from-blue-600 to-purple-600 bg-clip-text text-transparent">{{ firstName }}</span>!
              </h1>
              <!-- Role badge — role-specific color + icon, no article prefix -->
              <div class="mt-0.5">
                <span :class="['inline-flex items-center gap-1.5 px-2 py-0.5 rounded-md text-xs font-semibold', roleConfig.classes]">
                  <i :class="`fas ${roleConfig.icon} text-[10px]`"></i>
                  {{ roleName }}
                </span>
              </div>
            </div>
          </div>
        </div>

        <!-- Right: notifications + dark-mode toggle + search + quick action -->
        <div class="flex items-center gap-2 sm:gap-3">

          <!-- ── Notifications ── -->
          <div class="relative" ref="notificationsRef">
            <button
              @click.stop="showNotifications = !showNotifications"
              class="relative p-2 sm:p-2.5 rounded-xl text-tx-body hover:bg-surface-3 active:bg-surface-4 transition-all duration-200 touch-manipulation"
              aria-label="Notifications"
            >
              <i class="fas fa-bell text-lg"></i>
              <!-- Unread count badge — ring-surface matches the header bg in both modes -->
              <span
                v-if="unreadCount > 0"
                class="absolute -top-1 -right-1 w-5 h-5 bg-red-500 text-white text-xs font-bold rounded-full flex items-center justify-center ring-2 ring-surface animate-pulse"
              >
                {{ unreadCount > 9 ? '9+' : unreadCount }}
              </span>
            </button>

            <!-- Notifications dropdown -->
            <transition
              enter-active-class="transition ease-out duration-200"
              enter-from-class="opacity-0 scale-95"
              enter-to-class="opacity-100 scale-100"
              leave-active-class="transition ease-in duration-150"
              leave-from-class="opacity-100 scale-100"
              leave-to-class="opacity-0 scale-95"
            >
              <div
                v-if="showNotifications"
                class="absolute right-0 mt-2 w-[90vw] sm:w-96 bg-surface rounded-xl shadow-2xl border border-line overflow-hidden z-50"
              >
                <!-- Dropdown header -->
                <div class="p-4 border-b border-line bg-gradient-to-r from-blue-50 to-purple-50 dark:from-blue-950/40 dark:to-purple-950/40">
                  <div class="flex items-center justify-between">
                    <div>
                      <h3 class="font-semibold text-tx-primary">Notifications</h3>
                      <p class="text-xs text-tx-muted mt-0.5">
                        {{ unreadCount > 0
                            ? `You have ${unreadCount} unread notification${unreadCount !== 1 ? 's' : ''}`
                            : 'All caught up!' }}
                      </p>
                    </div>
                    <button
                      v-if="unreadCount > 0"
                      @click="markAllAsRead"
                      class="text-xs text-blue-600 hover:text-blue-700 dark:text-blue-400 dark:hover:text-blue-300
                             font-medium px-2 py-1 rounded hover:bg-blue-50 dark:hover:bg-blue-900/20 transition-colors"
                      title="Mark all as read"
                    >
                      Mark all read
                    </button>
                  </div>
                </div>

                <!-- Notification list -->
                <div class="max-h-[60vh] sm:max-h-96 overflow-y-auto">
                  <!-- Loading -->
                  <div v-if="isLoadingNotifications" class="p-8 text-center">
                    <div class="inline-block animate-spin rounded-full h-8 w-8 border-b-2 border-blue-600"></div>
                    <p class="text-sm text-tx-muted mt-2">Loading notifications…</p>
                  </div>

                  <!-- Empty -->
                  <div v-else-if="notifications.length === 0" class="p-8 text-center">
                    <svg class="mx-auto h-12 w-12 text-tx-subtle" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
                            d="M15 17h5l-1.405-1.405A2.032 2.032 0 0118 14.158V11a6.002 6.002 0 00-4-5.659V5a2 2 0 10-4 0v.341C7.67 6.165 6 8.388 6 11v3.159c0 .538-.214 1.055-.595 1.436L4 17h5m6 0v1a3 3 0 11-6 0v-1m6 0H9"/>
                    </svg>
                    <h3 class="mt-2 text-sm font-medium text-tx-primary">No notifications</h3>
                    <p class="mt-1 text-sm text-tx-subtle">You're all caught up!</p>
                  </div>

                  <!-- Items -->
                  <div
                    v-else
                    v-for="notif in notifications"
                    :key="notif.id"
                    @click="handleNotificationClick(notif)"
                    class="group relative p-4 hover:bg-surface-2 transition-colors duration-150 border-b border-line last:border-b-0 cursor-pointer"
                    :class="{ 'bg-blue-50/30 dark:bg-blue-900/10': !notif.read_at }"
                  >
                    <!-- Unread indicator dot -->
                    <div v-if="!notif.read_at" class="absolute left-2 top-1/2 -translate-y-1/2 w-2 h-2 bg-blue-600 rounded-full"></div>

                    <div class="flex items-start gap-3" :class="{ 'ml-3': !notif.read_at }">
                      <!-- Icon -->
                      <div class="flex-shrink-0 w-10 h-10 bg-gradient-to-br from-blue-500 to-purple-600 rounded-lg flex items-center justify-center text-white shadow-sm">
                        <i class="fas fa-clipboard-list text-sm"></i>
                      </div>

                      <!-- Body -->
                      <div class="flex-1 min-w-0">
                        <p class="text-sm text-tx-primary font-medium leading-snug mb-1">
                          {{ notif.data.message }}
                        </p>
                        <div class="flex flex-wrap items-center gap-2 mt-2">
                          <span
                            :class="getStatusBadgeColor(notif.data.status)"
                            class="inline-flex items-center px-2 py-0.5 rounded text-xs font-semibold"
                          >
                            {{ notif.data.status }}
                          </span>
                          <span class="text-xs text-tx-subtle">{{ notif.time_ago }}</span>
                        </div>
                        <div class="mt-1 text-xs text-tx-muted">
                          <span v-if="notif.data.control_number">Control #: {{ notif.data.control_number }}</span>
                          <span v-else>Req #: {{ notif.data.requisition_id }}</span>
                        </div>
                      </div>

                      <!-- Delete -->
                      <button
                        @click="deleteNotification(notif.id, $event)"
                        class="flex-shrink-0 opacity-0 group-hover:opacity-100 p-1 text-tx-subtle hover:text-red-600 dark:hover:text-red-400 transition-all duration-200"
                        title="Delete notification"
                      >
                        <svg class="w-4 h-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/>
                        </svg>
                      </button>
                    </div>
                  </div>
                </div>

                <!-- Footer -->
                <div class="p-3 border-t border-line bg-surface-2">
                  <a
                    href="/profile"
                    class="block text-sm text-blue-600 hover:text-blue-700 dark:text-blue-400 dark:hover:text-blue-300 font-medium text-center transition-colors"
                  >
                    Notification settings
                  </a>
                </div>
              </div>
            </transition>
          </div>

          <!-- ── Dark-mode pill toggle ──────────────────────────────────────── -->
          <button
            @click="toggle"
            class="relative inline-flex h-7 w-14 flex-shrink-0 items-center rounded-full transition-colors duration-300
                   focus:outline-none focus:ring-2 focus:ring-blue-500 focus:ring-offset-2 dark:focus:ring-offset-gray-900"
            :class="isDark ? 'bg-blue-600' : 'bg-surface-4'"
            :aria-label="isDark ? 'Switch to light mode' : 'Switch to dark mode'"
            :title="isDark  ? 'Switch to light mode' : 'Switch to dark mode'"
          >
            <span
              class="absolute inline-flex h-5 w-5 items-center justify-center rounded-full bg-white shadow-md transition-transform duration-300"
              :class="isDark ? 'translate-x-8' : 'translate-x-1'"
            >
              <i class="text-xs" :class="isDark ? 'fas fa-sun text-yellow-500' : 'fas fa-moon text-indigo-500'"></i>
            </span>
          </button>


        </div>
      </div>
    </div>

    <!-- Page-load progress bar — wired to isLoading prop -->
    <div
      class="h-0.5 bg-gradient-to-r from-blue-500 via-purple-500 to-pink-500 transform origin-left transition-transform duration-300"
      :class="props.isLoading ? 'scale-x-100' : 'scale-x-0'"
    ></div>
  </header>

</template>

<style scoped>
select { background-image: none; }

@media (hover: none) and (pointer: coarse) {
  button:active { transform: scale(0.97); }
}

/* Notification list scrollbar — light mode */
.overflow-y-auto {
  scrollbar-width: thin;
  scrollbar-color: rgb(209 213 219) transparent;
}
.overflow-y-auto::-webkit-scrollbar       { width: 6px; }
.overflow-y-auto::-webkit-scrollbar-track { background: transparent; }
.overflow-y-auto::-webkit-scrollbar-thumb { background: rgb(209 213 219); border-radius: 3px; }
.overflow-y-auto::-webkit-scrollbar-thumb:hover { background: rgb(156 163 175); }

/* Dark-mode override for scrollbar */
:global(.dark) .overflow-y-auto { scrollbar-color: rgb(75 85 99) transparent; }
:global(.dark) .overflow-y-auto::-webkit-scrollbar-thumb       { background: rgb(75 85 99); }
:global(.dark) .overflow-y-auto::-webkit-scrollbar-thumb:hover { background: rgb(107 114 128); }
</style>
