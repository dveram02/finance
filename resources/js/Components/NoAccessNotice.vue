<script setup>
/**
 * Shown when the signed-in user maps to no department at all.
 *
 * Distinct from both the outage warning and the "no results" empty state: this
 * is not a failure and not a filter problem, so it must not send the user to
 * retry or to clear filters. Kept to a single line deliberately — the state is
 * resolved by an administrator, not by anything the reader can do here.
 */
</script>

<template>
    <section
        class="flex items-center gap-3 rounded-xl border border-amber-300/60 bg-amber-50/70 px-5 py-4 dark:border-amber-500/30 dark:bg-amber-500/10"
        role="status"
    >
        <span
            class="grid h-9 w-9 shrink-0 place-items-center rounded-full bg-amber-100 text-amber-700 dark:bg-amber-500/20 dark:text-amber-300"
            aria-hidden="true"
        >
            <i class="fas fa-user-lock text-sm"></i>
        </span>

        <p class="font-display text-sm font-semibold text-tx-body">
            Department access is not configured
        </p>
    </section>
</template>
