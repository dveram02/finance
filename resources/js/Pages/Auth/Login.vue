<script setup>
import InputError from '@/Components/InputError.vue';
import { Head, useForm, usePage } from '@inertiajs/vue3';
import { computed, ref, watch, onMounted } from 'vue';
import { useDarkMode } from '@/composables/useDarkMode';

const props = defineProps({
    status: String,
    flash: Object,
    oldUsername: String,
});

const { isDark, init } = useDarkMode();
onMounted(() => init());

const page = usePage();
const appName = computed(() => page.props.appName || 'Finance');

const form = useForm({
    username: props.oldUsername || '',
    password: '',
    remember: false,
});

const showPassword = ref(false);

watch(
    () => props.flash?.error,
    (newError) => {
        if (newError) form.reset('password');
    }
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

  <div class="min-h-screen overflow-hidden bg-[#eef3f6] text-slate-950 transition-colors duration-300 dark:bg-[#07111f] dark:text-white">
    <div class="relative min-h-screen">
      <div class="absolute inset-0 bg-[radial-gradient(circle_at_18%_18%,rgba(14,116,144,0.22),transparent_30%),radial-gradient(circle_at_82%_8%,rgba(245,158,11,0.18),transparent_28%),linear-gradient(135deg,#f8fafc_0%,#dce8ef_48%,#c9d7e2_100%)] dark:bg-[radial-gradient(circle_at_18%_18%,rgba(34,211,238,0.16),transparent_30%),radial-gradient(circle_at_82%_8%,rgba(245,158,11,0.12),transparent_28%),linear-gradient(135deg,#07111f_0%,#0c1c2f_48%,#112a3c_100%)]"></div>
      <div class="absolute inset-0 opacity-[0.24] dark:opacity-[0.16]" style="background-image: linear-gradient(rgba(15, 23, 42, .12) 1px, transparent 1px), linear-gradient(90deg, rgba(15, 23, 42, .12) 1px, transparent 1px); background-size: 44px 44px;"></div>

      <main class="relative z-10 grid min-h-screen lg:grid-cols-[minmax(0,1.15fr)_minmax(420px,0.85fr)]">
        <section class="hidden min-h-screen flex-col justify-between p-10 lg:flex xl:p-14">
          <div class="flex items-center gap-4">
            <img :src="isDark ? '/images/logo_white.png' : '/images/logo.png'" alt="" class="h-14 w-auto" />
            <div>
              <p class="text-xs font-semibold uppercase tracking-[0.35em] text-cyan-800 dark:text-cyan-200">Secure finance portal</p>
              <p class="mt-1 text-lg font-semibold text-slate-950 dark:text-white">{{ appName }}</p>
            </div>
          </div>

          <div class="max-w-3xl">
            <div class="mb-8 inline-flex items-center gap-3 rounded-full border border-slate-900/10 bg-white/45 px-4 py-2 text-sm font-semibold text-slate-700 shadow-sm backdrop-blur dark:border-white/10 dark:bg-white/10 dark:text-slate-200">
              <span class="h-2 w-2 rounded-full bg-emerald-500 shadow-[0_0_18px_rgba(16,185,129,0.9)]"></span>
              Budget intelligence workspace
            </div>
            <h1 class="font-display text-6xl font-bold leading-[0.95] tracking-tight text-slate-950 dark:text-white xl:text-7xl">
              Command the numbers before they command the month.
            </h1>
            <p class="mt-8 max-w-2xl text-lg leading-8 text-slate-700 dark:text-slate-300">
              Review allocations, expenditure movement, and department signals from a focused executive finance environment.
            </p>
          </div>

          <div class="relative overflow-hidden rounded-[2rem] border border-white/40 bg-slate-950 shadow-2xl shadow-slate-950/25 dark:border-white/10">
            <img src="/images/bg-login.png" alt="" class="h-72 w-full object-cover opacity-85" />
            <div class="absolute inset-0 bg-gradient-to-tr from-slate-950 via-slate-950/45 to-transparent"></div>
            <div class="absolute bottom-0 left-0 right-0 grid grid-cols-3 gap-px bg-white/10 p-px">
              <div class="bg-white/10 p-5 backdrop-blur-md">
                <p class="text-xs uppercase tracking-[0.25em] text-cyan-100/80">Period</p>
                <p class="mt-2 text-2xl font-semibold text-white">FY</p>
              </div>
              <div class="bg-white/10 p-5 backdrop-blur-md">
                <p class="text-xs uppercase tracking-[0.25em] text-cyan-100/80">Mode</p>
                <p class="mt-2 text-2xl font-semibold text-white">Live</p>
              </div>
              <div class="bg-white/10 p-5 backdrop-blur-md">
                <p class="text-xs uppercase tracking-[0.25em] text-cyan-100/80">Access</p>
                <p class="mt-2 text-2xl font-semibold text-white">SSO</p>
              </div>
            </div>
          </div>
        </section>

        <section class="flex min-h-screen items-center justify-center px-5 py-8 sm:px-8 lg:px-10">
          <div class="w-full max-w-md">
            <div class="mb-8 flex items-center justify-center gap-4 lg:hidden">
              <img
                :src="isDark ? '/images/logo_white.png' : '/images/logo.png'"
                alt=""
                class="h-14 w-auto"
              />
              <div>
                <p class="text-xs font-semibold uppercase tracking-[0.28em] text-cyan-800 dark:text-cyan-200">Finance portal</p>
                <p class="text-lg font-semibold text-slate-950 dark:text-white">{{ appName }}</p>
              </div>
            </div>

            <div class="rounded-[1.75rem] border border-white/70 bg-white/80 p-6 shadow-[0_24px_80px_rgba(15,23,42,0.18)] backdrop-blur-xl dark:border-white/10 dark:bg-white/[0.08] sm:p-8">
              <div class="mb-8 hidden justify-center lg:flex">
                <img
                  :src="isDark ? '/images/logo_white.png' : '/images/logo.png'"
                  :alt="`${appName} logo`"
                  class="h-20 w-auto"
                />
              </div>

              <div class="mb-8 text-center">
                <p class="text-sm font-semibold uppercase tracking-[0.3em] text-cyan-700 dark:text-cyan-200">Welcome back</p>
                <h2 class="mt-3 text-3xl font-semibold tracking-tight text-slate-950 dark:text-white">Sign in to {{ appName }}</h2>
                <p class="mx-auto mt-3 max-w-sm text-sm leading-6 text-slate-600 dark:text-slate-300">
                  Use your assigned account to continue to budget and expenditure reporting.
                </p>
              </div>

              <div v-if="status"
                   class="mb-5 rounded-2xl border border-emerald-200 bg-emerald-50 px-4 py-3 text-sm font-medium text-emerald-800 dark:border-emerald-400/20 dark:bg-emerald-400/10 dark:text-emerald-200">
                {{ status }}
              </div>
              <div v-if="flash?.error"
                   class="mb-5 rounded-2xl border border-red-200 bg-red-50 px-4 py-3 text-sm font-medium text-red-800 dark:border-red-400/20 dark:bg-red-400/10 dark:text-red-200">
                {{ flash.error }}
              </div>

              <form @submit.prevent="submit" class="space-y-5">
                <div>
                  <label for="username" class="mb-2 block text-sm font-semibold text-slate-700 dark:text-slate-200">Username</label>
                  <div class="relative">
                    <span class="pointer-events-none absolute left-4 top-1/2 -translate-y-1/2 text-slate-400 dark:text-slate-500">
                      <i class="fa-solid fa-user"></i>
                    </span>
                    <input
                      id="username"
                      v-model="form.username"
                      type="text"
                      required
                      autocomplete="username"
                      class="w-full rounded-2xl border border-slate-200 bg-white/85 py-3.5 pl-11 pr-4 text-slate-950 shadow-sm transition placeholder:text-slate-400 focus:border-cyan-500 focus:bg-white focus:outline-none focus:ring-4 focus:ring-cyan-500/15 dark:border-white/10 dark:bg-slate-950/35 dark:text-white dark:placeholder:text-slate-500 dark:focus:border-cyan-300 dark:focus:bg-slate-950/55"
                      placeholder="Enter your username"
                    />
                  </div>
                  <InputError class="mt-2" :message="form.errors.username" />
                </div>

                <div>
                  <label for="password" class="mb-2 block text-sm font-semibold text-slate-700 dark:text-slate-200">Password</label>
                  <div class="relative">
                    <span class="pointer-events-none absolute left-4 top-1/2 -translate-y-1/2 text-slate-400 dark:text-slate-500">
                      <i class="fa-solid fa-lock"></i>
                    </span>
                    <input
                      id="password"
                      v-model="form.password"
                      :type="showPassword ? 'text' : 'password'"
                      required
                      autocomplete="current-password"
                      class="w-full rounded-2xl border border-slate-200 bg-white/85 py-3.5 pl-11 pr-12 text-slate-950 shadow-sm transition placeholder:text-slate-400 focus:border-cyan-500 focus:bg-white focus:outline-none focus:ring-4 focus:ring-cyan-500/15 dark:border-white/10 dark:bg-slate-950/35 dark:text-white dark:placeholder:text-slate-500 dark:focus:border-cyan-300 dark:focus:bg-slate-950/55"
                      placeholder="Enter your password"
                    />
                    <button
                      type="button"
                      @click="showPassword = !showPassword"
                      class="absolute right-3 top-1/2 flex h-9 w-9 -translate-y-1/2 items-center justify-center rounded-full text-slate-500 transition hover:bg-slate-100 hover:text-slate-800 focus:outline-none focus:ring-2 focus:ring-cyan-500 dark:text-slate-400 dark:hover:bg-white/10 dark:hover:text-white"
                      :aria-label="showPassword ? 'Hide password' : 'Show password'"
                    >
                      <i :class="showPassword ? 'fa-solid fa-eye-slash' : 'fa-solid fa-eye'"></i>
                    </button>
                  </div>
                  <InputError class="mt-2" :message="form.errors.password" />
                </div>

                <div class="flex items-center justify-between">
                  <label class="inline-flex cursor-pointer items-center">
                    <input
                      v-model="form.remember"
                      type="checkbox"
                      class="h-4 w-4 cursor-pointer rounded border-slate-300 text-cyan-700 focus:ring-cyan-500 dark:border-white/20 dark:bg-slate-950/40"
                    />
                    <span class="ml-2 text-sm font-medium text-slate-600 dark:text-slate-300">Remember me</span>
                  </label>
                  <span class="text-xs font-semibold uppercase tracking-[0.22em] text-slate-400 dark:text-slate-500">Protected</span>
                </div>

                <button
                  type="submit"
                  :disabled="form.processing"
                  class="group relative w-full overflow-hidden rounded-2xl bg-slate-950 px-4 py-3.5 text-sm font-bold uppercase tracking-[0.18em] text-white shadow-xl shadow-slate-950/20 transition hover:-translate-y-0.5 hover:bg-cyan-950 focus:outline-none focus:ring-4 focus:ring-cyan-500/25 disabled:cursor-not-allowed disabled:opacity-60 disabled:hover:translate-y-0 dark:bg-cyan-300 dark:text-slate-950 dark:shadow-cyan-950/20 dark:hover:bg-white"
                >
                  <span class="absolute inset-y-0 left-0 w-1/3 -translate-x-full bg-white/20 transition duration-700 group-hover:translate-x-[320%]"></span>
                  <span v-if="!form.processing" class="relative">Sign in</span>
                  <span v-else class="relative flex items-center justify-center gap-2">
                    <svg class="h-5 w-5 animate-spin" fill="none" viewBox="0 0 24 24">
                      <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                      <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
                    </svg>
                    Processing
                  </span>
                </button>
              </form>
            </div>
          </div>
        </section>
      </main>
    </div>
  </div>
</template>
