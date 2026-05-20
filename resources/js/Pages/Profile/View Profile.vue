<script setup>
import { computed } from 'vue'
import { Head, Link } from '@inertiajs/vue3'

const props = defineProps({
  user: { type: Object, required: true },
})

const user = computed(() => props.user)

const getInitials = (name) => {
  if (!name) return '?'
  return name.split(' ').map(n => n[0]).join('').toUpperCase().slice(0, 2)
}

const roleName = computed(() => {
  const roles = user.value?.roles ?? []
  if (!roles.length) return 'No Role'
  return typeof roles[0] === 'object' ? roles[0].name : roles[0]
})
</script>

<template>
  <Head title="My Profile" />

  <div class="py-8 px-4 sm:px-6 lg:px-8">
      <div class="mx-auto max-w-lg">

        <!-- Profile card -->
        <div class="bg-surface rounded-xl shadow-sm border border-line overflow-hidden">

          <!-- Card header -->
          <div class="bg-gradient-to-r from-blue-600 to-indigo-600 px-6 py-8 flex flex-col items-center text-center">
            <div class="w-20 h-20 rounded-full bg-white/20 flex items-center justify-center mb-3 shadow-lg">
              <span class="text-2xl font-bold text-white">{{ getInitials(user.name) }}</span>
            </div>
            <h1 class="text-xl font-bold text-white">{{ user.name }}</h1>
            <span class="mt-2 inline-flex items-center px-3 py-1 rounded-full text-xs font-semibold bg-white/20 text-white">
              {{ roleName }}
            </span>
          </div>

          <!-- Card body -->
          <div class="px-6 py-6 space-y-4">

            <div class="flex items-start gap-3">
              <div class="mt-0.5 w-8 h-8 rounded-lg bg-indigo-50 dark:bg-indigo-900/30 flex items-center justify-center flex-shrink-0">
                <i class="fas fa-user text-indigo-500 text-sm"></i>
              </div>
              <div>
                <p class="text-xs font-medium text-tx-subtle uppercase tracking-wide">Employee Name</p>
                <p class="mt-0.5 text-sm text-tx-primary font-medium">{{ user.name || '—' }}</p>
              </div>
            </div>

            <div class="flex items-start gap-3">
              <div class="mt-0.5 w-8 h-8 rounded-lg bg-indigo-50 dark:bg-indigo-900/30 flex items-center justify-center flex-shrink-0">
                <i class="fas fa-at text-indigo-500 text-sm"></i>
              </div>
              <div>
                <p class="text-xs font-medium text-tx-subtle uppercase tracking-wide">Username</p>
                <p class="mt-0.5 text-sm text-tx-primary font-medium">{{ user.username || user.email || '—' }}</p>
              </div>
            </div>

            <div class="flex items-start gap-3">
              <div class="mt-0.5 w-8 h-8 rounded-lg bg-indigo-50 dark:bg-indigo-900/30 flex items-center justify-center flex-shrink-0">
                <i class="fas fa-id-badge text-indigo-500 text-sm"></i>
              </div>
              <div>
                <p class="text-xs font-medium text-tx-subtle uppercase tracking-wide">Employee ID</p>
                <p class="mt-0.5 text-sm text-tx-primary font-medium">{{ user.employee_id || user.id || '—' }}</p>
              </div>
            </div>

          </div>

          <!-- Card footer -->
          <div class="px-6 py-4 border-t border-line bg-surface-2">
            <Link
              :href="route('dashboard')"
              class="inline-flex items-center gap-2 text-sm font-medium text-blue-600 hover:text-blue-700 dark:text-blue-400 dark:hover:text-blue-300 transition-colors"
            >
              <i class="fas fa-arrow-left text-xs"></i>
              Back to Dashboard
            </Link>
          </div>

        </div>

      </div>
    </div>
</template>
