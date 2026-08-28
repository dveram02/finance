<script setup>
import { computed } from 'vue'

/**
 * "As at ..." for a snapshot-backed page.
 *
 * The requisition detail is rebuilt by step 2 of the nightly SQL Agent job, so
 * a requisition raised this morning is not on the page yet. That trade —
 * freshness given up in exchange for detail that reconciles to the summary —
 * is only honest if the page says when the figures are from, which is why this
 * exists at all rather than the pages quietly reading as live.
 *
 * Deliberately not a warning: being a day old is the DESIGNED state, not a
 * fault. Amber here would train people to ignore amber everywhere else.
 */
const props = defineProps({
    // ISO 8601 string, or null when the snapshot has never built or the probe
    // could not run. Those two are not distinguished on purpose — neither means
    // anything the reader can act on, and both mean "do not trust a timestamp".
    refreshedAt: { type: String, default: null },
    // Server-rendered relative age ("21 hours ago"), so the page and the health
    // check agree on the clock. The DB server writes RefreshedAt with
    // SYSDATETIME(); computing "ago" in the browser would use a third clock.
    age: { type: String, default: null },
})

const exact = computed(() => {
    if (!props.refreshedAt) return null

    const at = new Date(props.refreshedAt)
    if (Number.isNaN(at.getTime())) return null

    return at.toLocaleString('en-TT', {
        year: 'numeric', month: 'short', day: 'numeric',
        hour: '2-digit', minute: '2-digit',
    })
})
</script>

<template>
    <p class="flex items-center justify-center gap-2 text-xs text-tx-subtle" :title="refreshedAt || undefined">
        <i class="fas fa-clock-rotate-left text-[10px]" aria-hidden="true"></i>
        <template v-if="exact">
            Requisition detail as at
            <span class="font-semibold text-tx-body">{{ exact }}</span>
            <span v-if="age" class="text-tx-subtle/80">({{ age }})</span>
            · rebuilt nightly, not live
        </template>
        <template v-else>
            Refresh time unavailable — these figures are from the last completed nightly build, not live
        </template>
    </p>
</template>
