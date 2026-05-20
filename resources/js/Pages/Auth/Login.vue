<script setup>
import InputError from '@/Components/InputError.vue';
import { Head, useForm } from '@inertiajs/vue3';
import { ref, watch, onMounted } from 'vue';
import { useDarkMode } from '@/composables/useDarkMode';

const props = defineProps({
    status: String,
    flash: Object,
    oldUsername: String,
});

const { isDark, init } = useDarkMode();
onMounted(() => init());

const form = useForm({
    username: props.oldUsername || '',
    password: '',
    remember: false,
});

const showPassword = ref(false);

watch(
  () => props.flash?.error,
  (newError) => { if (newError) form.reset('password'); }
);

const submit = () => {
    form.post(route('login'), {
        replace: true,
        onFinish: () => form.reset('password'),
    });
};
</script>

<template>
  <Head title="Log In" />

  <div class="min-h-screen flex">
    <!-- Left: background image panel (desktop only) -->
    <div
      class="hidden lg:block lg:w-3/5 xl:w-2/3 bg-cover bg-center"
      style="background-image: url('/images/bg-login.png')"
    ></div>

    <!-- Right: login form -->
    <div class="w-full lg:w-2/5 xl:w-1/3 bg-surface flex flex-col justify-center px-8 sm:px-12 lg:px-16 py-12 transition-colors duration-300">
      <div class="w-full max-w-md mx-auto">

        <!-- Logo — logo_white.png in dark mode for visibility on dark background -->
        <div class="flex justify-center mb-12">
          <img
            :src="isDark ? '/images/logo_white.png' : '/images/logo.png'"
            alt="Logo"
            class="h-24 w-auto"
          />
        </div>

        <!-- Status / flash messages -->
        <div v-if="status"
             class="mb-6 p-4 bg-green-50 border border-green-200 text-green-800 rounded-lg text-sm text-center
                    dark:bg-green-900/20 dark:border-green-800 dark:text-green-400">
          {{ status }}
        </div>
        <div v-if="flash?.error"
             class="mb-6 p-4 bg-red-50 border border-red-200 text-red-800 rounded-lg text-sm text-center
                    dark:bg-red-900/20 dark:border-red-800 dark:text-red-400">
          {{ flash.error }}
        </div>

        <form @submit.prevent="submit" class="space-y-6">

          <!-- Username -->
          <div>
            <label for="username" class="block text-sm font-medium text-tx-body mb-2">Username</label>
            <input
              id="username"
              v-model="form.username"
              type="text"
              required
              autocomplete="username"
              class="w-full px-4 py-3 bg-surface-2 border border-line-input rounded-lg text-tx-primary
                     placeholder-gray-400 dark:placeholder-gray-500
                     focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent
                     focus:bg-surface transition-all"
              placeholder="Enter your username"
            />
            <InputError class="mt-2" :message="form.errors.username" />
          </div>

          <!-- Password -->
          <div>
            <label for="password" class="block text-sm font-medium text-tx-body mb-2">Password</label>
            <div class="relative">
              <input
                id="password"
                v-model="form.password"
                :type="showPassword ? 'text' : 'password'"
                required
                autocomplete="current-password"
                class="w-full px-4 py-3 bg-surface-2 border border-line-input rounded-lg text-tx-primary
                       placeholder-gray-400 dark:placeholder-gray-500
                       focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-transparent
                       focus:bg-surface transition-all pr-12"
                placeholder="Enter your password"
              />
              <!-- Show/hide toggle -->
              <button
                type="button"
                @click="showPassword = !showPassword"
                class="absolute right-3 top-1/2 -translate-y-1/2 text-tx-subtle hover:text-tx-muted transition-colors"
              >
                <svg v-if="!showPassword" class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
                        d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"/>
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
                        d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z"/>
                </svg>
                <svg v-else class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
                        d="M13.875 18.825A10.05 10.05 0 0112 19c-4.478 0-8.268-2.943-9.543-7a9.97 9.97 0 011.563-3.029m5.858.908a3 3 0 114.243 4.243M9.878 9.878l4.242 4.242M9.88 9.88l-3.29-3.29m7.532 7.532l3.29 3.29M3 3l3.59 3.59m0 0A9.953 9.953 0 0112 5c4.478 0 8.268 2.943 9.543 7a10.025 10.025 0 01-4.132 5.411m0 0L21 21"/>
                </svg>
              </button>
            </div>
            <InputError class="mt-2" :message="form.errors.password" />
          </div>

          <!-- Remember me -->
          <div class="flex items-center">
            <label class="inline-flex items-center cursor-pointer">
              <input
                v-model="form.remember"
                type="checkbox"
                class="w-4 h-4 rounded border-line-input text-blue-600 focus:ring-blue-500 cursor-pointer"
              />
              <span class="ml-2 text-sm text-tx-body">Remember me</span>
            </label>
          </div>

          <!-- Submit -->
          <button
            type="submit"
            :disabled="form.processing"
            class="w-full py-3 px-4 bg-blue-600 text-white font-medium rounded-lg
                   hover:bg-blue-700 focus:outline-none focus:ring-2 focus:ring-blue-500
                   focus:ring-offset-2 dark:focus:ring-offset-gray-900
                   disabled:opacity-50 disabled:cursor-not-allowed transition-all shadow-sm"
          >
            <span v-if="!form.processing">Login</span>
            <span v-else class="flex items-center justify-center gap-2">
              <svg class="animate-spin h-5 w-5" fill="none" viewBox="0 0 24 24">
                <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
              </svg>
              Processing…
            </span>
          </button>
        </form>
      </div>
    </div>
  </div>
</template>
