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
  if (hour < 12) return 'fa-sun text-amber-500';
  if (hour < 18) return 'fa-cloud-sun text-amber-400';
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

// Status badge colours
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
  <header class="sticky top-0 bg-surface/90 backdrop-blur-md border-b border-line/50 z-30 transition-all duration-300 w-full shadow-sm">
    <div class="px-5 sm:px-7 py-3.5">

      <div class="flex items-center justify-between gap-4">

        <!-- Left: mobile toggle + greeting -->
        <div class="flex items-center gap-3 min-w-0">
          <!-- Mobile hamburger -->
          <button
            class="p-2 rounded-xl text-tx-body hover:bg-surface-3 active:bg-surface-4 md:hidden transition-all duration-200 flex-shrink-0"
            @click="$emit('toggle-mobile')"
            aria-label="Toggle menu"
          >
            <i class="fas fa-bars text-base"></i>
          </button>

          <!-- Greeting -->
          <div class="flex items-center gap-3 min-w-0">
            <div class="hidden sm:flex w-9 h-9 rounded-xl items-center justify-center flex-shrink-0 bg-surface-3">
              <i :class="`fas ${greetingIcon} text-base`"></i>
            </div>
            <div class="min-w-0">
              <div class="flex items-baseline gap-1.5 flex-wrap">
                <span class="text-sm text-tx-muted font-medium">{{ greeting }},</span>
                <span class="font-display text-lg font-bold text-tx-primary leading-tight">{{ firstName }}</span>
              </div>
              <div class="mt-0.5">
                <span :class="['inline-flex items-center gap-1.5 px-2 py-0.5 rounded-md text-xs font-semibold', roleConfig.classes]">
                  <i :class="`fas ${roleConfig.icon} text-[9px]`"></i>
                  {{ roleName }}
                </span>
              </div>
            </div>
          </div>
        </div>

        <!-- Right: notifications + dark-mode toggle -->
        <div class="flex items-center gap-2 flex-shrink-0">

          <!-- ── Notifications ── -->
          <div class="relative" ref="notificationsRef">
            <button
              @click.stop="showNotifications = !showNotifications"
              class="relative p-2 rounded-xl text-tx-body hover:bg-surface-3 active:bg-surface-4 transition-all duration-200"
              aria-label="Notifications"
            >
              <i class="fas fa-bell text-base"></i>
              <span
                v-if="unreadCount > 0"
                class="absolute -top-1 -right-1 w-4.5 h-4.5 min-w-[18px] min-h-[18px] bg-red-500 text-white text-[10px] font-bold rounded-full flex items-center justify-center ring-2 ring-surface animate-pulse px-1"
              >
                {{ unreadCount > 9 ? '9+' : unreadCount }}
              </span>
            </button>

            <!-- Notifications dropdown -->
            <transition
              enter-active-class="transition ease-out duration-200"
              enter-from-class="opacity-0 scale-95 translate-y-1"
              enter-to-class="opacity-100 scale-100 translate-y-0"
              leave-active-class="transition ease-in duration-150"
              leave-from-class="opacity-100 scale-100 translate-y-0"
              leave-to-class="opacity-0 scale-95 translate-y-1"
            >
              <div
                v-if="showNotifications"
                class="absolute right-0 mt-2 w-[90vw] sm:w-96 bg-surface rounded-xl shadow-2xl border border-line overflow-hidden z-50"
              >
                <!-- Dropdown header -->
                <div class="px-4 py-3 border-b border-line bg-surface-2">
                  <div class="flex items-center justify-between">
                    <div>
                      <h3 class="font-semibold text-sm text-tx-primary">Notifications</h3>
                      <p class="text-xs text-tx-muted mt-0.5">
                        {{ unreadCount > 0
                            ? `${unreadCount} unread`
                            : 'All caught up' }}
                      </p>
                    </div>
                    <button
                      v-if="unreadCount > 0"
                      @click="markAllAsRead"
                      class="text-xs text-blue-600 hover:text-blue-700 dark:text-blue-400 dark:hover:text-blue-300 font-medium px-2 py-1 rounded hover:bg-blue-50 dark:hover:bg-blue-900/20 transition-colors"
                    >
                      Mark all read
                    </button>
                  </div>
                </div>

                <!-- Notification list -->
                <div class="max-h-[60vh] sm:max-h-96 overflow-y-auto notif-scroll">
                  <!-- Loading -->
                  <div v-if="isLoadingNotifications" class="p-8 text-center">
                    <div class="inline-block animate-spin rounded-full h-6 w-6 border-b-2 border-amber-500"></div>
                    <p class="text-xs text-tx-muted mt-2">Loading…</p>
                  </div>

                  <!-- Empty -->
                  <div v-else-if="notifications.length === 0" class="p-8 text-center">
                    <i class="fas fa-bell-slash text-2xl text-tx-subtle mb-2 block"></i>
                    <h3 class="text-sm font-medium text-tx-primary">No notifications</h3>
                    <p class="mt-0.5 text-xs text-tx-subtle">You're all caught up!</p>
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
                    <div v-if="!notif.read_at" class="absolute left-2 top-1/2 -translate-y-1/2 w-1.5 h-1.5 bg-amber-500 rounded-full"></div>

                    <div class="flex items-start gap-3" :class="{ 'ml-3': !notif.read_at }">
                      <div class="flex-shrink-0 w-9 h-9 rounded-lg flex items-center justify-center text-white shadow-sm"
                           style="background: linear-gradient(135deg, #d97706, #b45309);">
                        <i class="fas fa-clipboard-list text-xs"></i>
                      </div>

                      <div class="flex-1 min-w-0">
                        <p class="text-sm text-tx-primary font-medium leading-snug mb-1">
                          {{ notif.data.message }}
                        </p>
                        <div class="flex flex-wrap items-center gap-2 mt-1.5">
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
                        title="Delete"
                      >
                        <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                          <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M6 18L18 6M6 6l12 12"/>
                        </svg>
                      </button>
                    </div>
                  </div>
                </div>

                <!-- Footer -->
                <div class="px-4 py-2.5 border-t border-line bg-surface-2">
                  <a
                    href="/profile"
                    class="block text-xs text-tx-muted hover:text-tx-primary font-medium text-center transition-colors"
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
            class="relative inline-flex h-7 w-13 flex-shrink-0 items-center rounded-full transition-colors duration-300
                   focus:outline-none focus:ring-2 focus:ring-amber-500 focus:ring-offset-2"
            :class="isDark ? 'bg-slate-700' : 'bg-surface-4'"
            :aria-label="isDark ? 'Switch to light mode' : 'Switch to dark mode'"
            style="width: 52px;"
          >
            <span
              class="absolute inline-flex h-5 w-5 items-center justify-center rounded-full bg-white shadow-md transition-transform duration-300"
              :class="isDark ? 'translate-x-7' : 'translate-x-1'"
            >
              <i class="text-[10px]" :class="isDark ? 'fas fa-sun text-amber-500' : 'fas fa-moon text-slate-500'"></i>
            </span>
          </button>

        </div>
      </div>
    </div>

    <!-- Page-load progress bar -->
    <div
      class="h-0.5 transform origin-left transition-transform duration-300"
      style="background: linear-gradient(90deg, #d97706, #f59e0b, #fbbf24);"
      :class="props.isLoading ? 'scale-x-100' : 'scale-x-0'"
    ></div>
  </header>
</template>

<style scoped>
select { background-image: none; }

@media (hover: none) and (pointer: coarse) {
  button:active { transform: scale(0.97); }
}

.notif-scroll {
  scrollbar-width: thin;
  scrollbar-color: rgb(209 213 219) transparent;
}
.notif-scroll::-webkit-scrollbar       { width: 4px; }
.notif-scroll::-webkit-scrollbar-track { background: transparent; }
.notif-scroll::-webkit-scrollbar-thumb { background: rgb(209 213 219); border-radius: 2px; }

:global(.dark) .notif-scroll { scrollbar-color: rgb(42 64 108) transparent; }
:global(.dark) .notif-scroll::-webkit-scrollbar-thumb { background: rgb(42 64 108); }
</style>
