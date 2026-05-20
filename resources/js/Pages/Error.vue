<script setup>
import { computed } from 'vue'
import { Link, usePage } from '@inertiajs/vue3'

const page = usePage()

defineOptions({ layout: null })

const props = defineProps({
    status: {
        type: Number,
        required: true,
    },
})

const error = computed(() => {
    const errors = {
        403: {
            title: 'Access Denied',
            description: "You don't have permission to access this page. Contact your administrator if you believe this is a mistake.",
            icon: 'fas fa-lock',
            color: 'red',
            gradient: 'from-red-500 to-rose-600',
            iconBg: 'bg-red-50',
            iconColor: 'text-red-500',
            codeColor: 'text-red-100',
        },
        404: {
            title: 'Page Not Found',
            description: "The page you're looking for doesn't exist or may have been moved.",
            icon: 'fas fa-search',
            color: 'blue',
            gradient: 'from-blue-500 to-indigo-600',
            iconBg: 'bg-blue-50',
            iconColor: 'text-blue-500',
            codeColor: 'text-blue-100',
        },
        419: {
            title: 'Page Expired',
            description: 'Your session has expired. Please refresh the page and try again.',
            icon: 'fas fa-clock',
            color: 'amber',
            gradient: 'from-amber-400 to-orange-500',
            iconBg: 'bg-amber-50',
            iconColor: 'text-amber-500',
            codeColor: 'text-amber-100',
        },
        429: {
            title: 'Too Many Requests',
            description: 'You have made too many requests in a short period. Please wait a moment before trying again.',
            icon: 'fas fa-exclamation-triangle',
            color: 'amber',
            gradient: 'from-amber-400 to-orange-500',
            iconBg: 'bg-amber-50',
            iconColor: 'text-amber-500',
            codeColor: 'text-amber-100',
        },
        500: {
            title: 'Server Error',
            description: "Something went wrong on our end. We've been notified and are working to resolve the issue.",
            icon: 'fas fa-server',
            color: 'red',
            gradient: 'from-red-500 to-rose-600',
            iconBg: 'bg-red-50',
            iconColor: 'text-red-500',
            codeColor: 'text-red-100',
        },
        503: {
            title: 'Service Unavailable',
            description: `${page.props.appName} is temporarily unavailable for scheduled maintenance. Please check back shortly.`,
            icon: 'fas fa-tools',
            color: 'amber',
            gradient: 'from-amber-400 to-orange-500',
            iconBg: 'bg-amber-50',
            iconColor: 'text-amber-500',
            codeColor: 'text-amber-100',
        },
    }

    return errors[props.status] ?? {
        title: 'An Error Occurred',
        description: 'An unexpected error occurred. Please try again or contact support if the problem persists.',
        icon: 'fas fa-exclamation-circle',
        color: 'gray',
        gradient: 'from-gray-400 to-slate-500',
        iconBg: 'bg-surface-2',
        iconColor: 'text-tx-subtle',
        codeColor: 'text-gray-100',
    }
})

function goBack() {
    window.history.back()
}
</script>

<template>
    <Head :title="`${status} — ${error.title}`" />

    <div class="min-h-screen bg-gradient-to-br from-gray-50 via-blue-50/30 to-purple-50/30 flex flex-col items-center justify-center px-4 font-sans antialiased">

        <!-- Brand header -->
        <div class="mb-10 text-center">
            <div class="inline-flex items-center gap-2.5 mb-1">
                <div class="w-8 h-8 bg-gradient-to-br from-blue-600 to-purple-600 rounded-lg flex items-center justify-center shadow-md">
                    <i class="fas fa-warehouse text-white text-sm"></i>
                </div>
                <span class="text-xl font-bold text-gray-800">{{ page.props.appName }}</span>
            </div>
            <p class="text-xs text-gray-400 tracking-widest uppercase">Inventory Management System</p>
        </div>

        <!-- Error card -->
        <div class="w-full max-w-lg">
            <div class="bg-surface rounded-2xl shadow-xl border border-gray-100 overflow-hidden">

                <!-- Accent strip -->
                <div :class="`h-1.5 w-full bg-gradient-to-r ${error.gradient}`"></div>

                <div class="px-8 py-10 text-center">

                    <!-- Status code (large, muted) -->
                    <div class="mb-4 leading-none">
                        <span :class="`text-9xl font-extrabold tracking-tight ${error.codeColor}`">
                            {{ status }}
                        </span>
                    </div>

                    <!-- Icon badge -->
                    <div :class="`w-16 h-16 rounded-full ${error.iconBg} flex items-center justify-center mx-auto mb-5 -mt-8 shadow-sm`">
                        <i :class="`${error.icon} text-2xl ${error.iconColor}`"></i>
                    </div>

                    <!-- Title -->
                    <h1 class="text-2xl font-bold text-tx-primary mb-3">{{ error.title }}</h1>

                    <!-- Description -->
                    <p class="text-tx-subtle text-sm leading-relaxed mb-8 max-w-sm mx-auto">
                        {{ error.description }}
                    </p>

                    <!-- Actions -->
                    <div class="flex flex-col sm:flex-row items-center justify-center gap-3">
                        <Link
                            :href="route('dashboard')"
                            class="inline-flex items-center justify-center gap-2 bg-gradient-to-r from-blue-600 to-indigo-600 text-white text-sm font-semibold px-6 py-2.5 rounded-lg shadow-md hover:shadow-lg hover:from-blue-700 hover:to-indigo-700 transition-all duration-200 w-full sm:w-auto"
                        >
                            <i class="fas fa-home text-xs"></i>
                            Back to Dashboard
                        </Link>
                        <button
                            type="button"
                            @click="goBack"
                            class="inline-flex items-center justify-center gap-2 bg-surface text-tx-body text-sm font-semibold px-6 py-2.5 rounded-lg border border-line hover:bg-surface-2 hover:border-line-input transition-all duration-200 w-full sm:w-auto"
                        >
                            <i class="fas fa-arrow-left text-xs"></i>
                            Go Back
                        </button>
                    </div>
                </div>
            </div>

            <p class="text-center text-xs text-gray-400 mt-6">
                If this problem persists, please contact your system administrator.
            </p>
        </div>
    </div>
</template>
