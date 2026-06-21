<script setup>
import { computed } from 'vue'
import { Head, Link } from '@inertiajs/vue3'
import { useDarkMode } from '@/composables/useDarkMode'

const props = defineProps({
  user: { type: Object, required: true },
})

const { isDark } = useDarkMode()
const user = computed(() => props.user)

const getInitials = (name) => {
  if (!name) return '?'
  return name.split(' ').map(n => n[0]).join('').toUpperCase().slice(0, 2)
}
</script>

<template>
  <Head title="My Profile" />

  <div class="max-w-4xl mx-auto space-y-6">

    <!-- Hero Card -->
    <div class="rounded-xl overflow-hidden border border-line shadow-sm">
      <div
        class="relative px-7 py-10 overflow-hidden"
        :style="isDark
          ? 'background: linear-gradient(135deg, #0b1625 0%, #0e2040 50%, #0b1625 100%);'
          : 'background: linear-gradient(135deg, #1d4ed8 0%, #4338ca 60%, #6d28d9 100%);'"
      >
        <!-- Dot-grid pattern -->
        <div class="absolute inset-0 opacity-5"
             style="background-image: radial-gradient(circle at 1px 1px, rgba(255,255,255,0.4) 1px, transparent 0); background-size: 24px 24px;"></div>
        <!-- Gold accent top bar -->
        <div class="absolute top-0 left-0 right-0 h-0.5"
             style="background: linear-gradient(90deg, #d97706, #f59e0b 40%, transparent 100%);"></div>
        <!-- Decorative circle blur -->
        <div class="absolute -right-16 -top-16 w-64 h-64 rounded-full opacity-10"
             style="background: radial-gradient(circle, #f59e0b 0%, transparent 70%);"></div>

        <div class="relative flex items-center gap-6">
          <!-- Avatar -->
          <div
            class="w-20 h-20 rounded-2xl flex items-center justify-center flex-shrink-0 shadow-xl border border-white/20"
            style="background: linear-gradient(135deg, rgba(217,119,6,0.75) 0%, rgba(245,158,11,0.55) 100%);"
          >
            <span class="font-display text-3xl font-bold text-white tracking-tight">{{ getInitials(user.name) }}</span>
          </div>

          <!-- Name + meta -->
          <div class="flex-1 min-w-0">
            <p class="text-xs font-semibold text-white/50 uppercase tracking-widest mb-1">My Profile</p>
            <h1 class="font-display text-2xl font-bold text-white leading-tight truncate">{{ user.name }}</h1>
            <div class="flex items-center gap-3 mt-2.5 flex-wrap">
              <div class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full bg-white/10 border border-white/15">
                <span class="w-1.5 h-1.5 rounded-full bg-emerald-400 animate-pulse"></span>
                <span class="text-xs font-semibold text-white/80">Active</span>
              </div>
              <div class="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full bg-white/10 border border-white/15">
                <i class="fas fa-building text-[10px] text-white/60"></i>
                <span class="text-xs font-medium text-white/70">Finance Portal</span>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>

    <!-- Main Content Grid -->
    <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">

      <!-- Left: Account Information -->
      <div class="lg:col-span-2">
        <section class="bg-surface border border-line rounded-xl overflow-hidden shadow-sm">
          <header class="px-6 py-4 bg-surface-2 border-b border-line flex items-center gap-2">
            <div class="w-7 h-7 rounded-lg flex items-center justify-center flex-shrink-0"
                 style="background: rgba(245,158,11,0.12);">
              <i class="fas fa-id-card text-xs" style="color: #d97706;"></i>
            </div>
            <h2 class="text-sm font-semibold text-tx-primary">Account Information</h2>
          </header>
          <div class="px-6 py-5">
            <dl class="space-y-5">

              <!-- Employee Name -->
              <div class="flex items-start gap-4">
                <div class="w-9 h-9 rounded-xl flex items-center justify-center flex-shrink-0 mt-0.5"
                     style="background: rgba(245,158,11,0.1);">
                  <i class="fas fa-user text-xs" style="color: #d97706;"></i>
                </div>
                <div class="flex-1 min-w-0">
                  <dt class="text-[10px] font-semibold text-tx-subtle uppercase tracking-widest">Employee Name</dt>
                  <dd class="mt-1 text-sm font-semibold text-tx-primary truncate">{{ user.name || '—' }}</dd>
                </div>
              </div>

              <div class="border-t border-line"></div>

              <!-- Username -->
              <div class="flex items-start gap-4">
                <div class="w-9 h-9 rounded-xl flex items-center justify-center flex-shrink-0 mt-0.5"
                     style="background: rgba(20,184,166,0.1);">
                  <i class="fas fa-at text-xs" style="color: #0d9488;"></i>
                </div>
                <div class="flex-1 min-w-0">
                  <dt class="text-[10px] font-semibold text-tx-subtle uppercase tracking-widest">Username</dt>
                  <dd class="mt-1 text-sm font-semibold text-tx-primary truncate">{{ user.username || '—' }}</dd>
                </div>
              </div>

              <div class="border-t border-line"></div>

              <!-- Employee ID -->
              <div class="flex items-start gap-4">
                <div class="w-9 h-9 rounded-xl flex items-center justify-center flex-shrink-0 mt-0.5"
                     style="background: rgba(99,102,241,0.1);">
                  <i class="fas fa-id-badge text-xs" style="color: #6366f1;"></i>
                </div>
                <div class="flex-1 min-w-0">
                  <dt class="text-[10px] font-semibold text-tx-subtle uppercase tracking-widest">Employee ID</dt>
                  <dd class="mt-1 text-sm font-semibold text-tx-primary truncate">{{ user.employee_id ?? '—' }}</dd>
                </div>
              </div>

            </dl>
          </div>
        </section>
      </div>

      <!-- Right: Account Status -->
      <div class="space-y-6">

        <!-- Status Card -->
        <section class="bg-surface border border-line rounded-xl overflow-hidden shadow-sm">
          <header class="px-6 py-4 bg-surface-2 border-b border-line flex items-center gap-2">
            <div class="w-7 h-7 rounded-lg flex items-center justify-center flex-shrink-0"
                 style="background: rgba(16,185,129,0.12);">
              <i class="fas fa-shield-alt text-xs" style="color: #059669;"></i>
            </div>
            <h2 class="text-sm font-semibold text-tx-primary">Account Status</h2>
          </header>
          <div class="px-6 py-5 space-y-4">
            <div>
              <dt class="text-[10px] font-semibold text-tx-subtle uppercase tracking-widest">Access Level</dt>
              <dd class="mt-2">
                <span class="inline-flex items-center gap-1.5 px-3 py-1 rounded-full text-xs font-semibold
                             bg-emerald-100 text-emerald-800 border border-emerald-200
                             dark:bg-emerald-900/30 dark:text-emerald-400 dark:border-emerald-800/50">
                  <span class="w-1.5 h-1.5 rounded-full bg-emerald-500 animate-pulse"></span>
                  Active
                </span>
              </dd>
            </div>
            <div class="border-t border-line pt-4">
              <dt class="text-[10px] font-semibold text-tx-subtle uppercase tracking-widest">Portal</dt>
              <dd class="mt-1.5 text-sm font-medium text-tx-primary">Finance Management</dd>
            </div>
            <div class="border-t border-line pt-4">
              <dt class="text-[10px] font-semibold text-tx-subtle uppercase tracking-widest">Account Type</dt>
              <dd class="mt-1.5 text-sm font-medium text-tx-primary">Staff</dd>
            </div>
          </div>
        </section>

      </div>
    </div>

    <!-- Footer Actions -->
    <div class="flex items-center justify-between gap-3 pt-1 pb-4">
      <Link
        :href="route('dashboard')"
        class="inline-flex items-center gap-2 px-4 py-2 text-sm font-medium text-tx-body bg-surface border border-line rounded-lg hover:bg-surface-2 transition-colors"
      >
        <i class="fas fa-arrow-left text-xs"></i>
        Back to Dashboard
      </Link>
      <span class="text-[10px] text-tx-subtle font-medium uppercase tracking-wider">Read-only</span>
    </div>

  </div>
</template>
