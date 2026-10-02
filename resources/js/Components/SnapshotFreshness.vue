<script setup>
import { computed } from 'vue'

/**
 * The single authority on what a snapshot-backed page says about its own data.
 *
 * The requisition detail is rebuilt by step 2 of the nightly SQL Agent job, so
 * a requisition raised this morning is not on the page yet. That trade —
 * freshness given up in exchange for detail that reconciles to the summary — is
 * only honest if the page says when the figures are from, which is why this
 * exists at all rather than the pages quietly reading as live.
 *
 * FOUR STATES, and the split between them is the whole point (2026-10-02).
 * "A night old" and "the nightly job stopped running three days ago" look
 * identical in a relative age and mean completely different things, and a
 * stopped Agent job produces no error of any kind — pages keep loading fast and
 * the figures simply stop moving. With no monitoring configured on production,
 * this is currently the only place a user could notice.
 *
 *   ok       quiet. Being a night old is the DESIGNED state, not a fault, and
 *            amber here would train people to ignore amber everywhere else.
 *   stale    amber. The last good build is past the configured limit — the same
 *            limit `ledger:status` alerts on, shared through config.
 *   failed   amber. The newest run aborted. The previous snapshot still stands
 *            and still reconciles, so the figures are usable; they just will not
 *            move again until someone looks.
 *   unknown  quiet GREY, never amber. The probe could not run, so we do not
 *            know — claiming a fault we cannot establish sends someone to chase
 *            the wrong thing.
 *
 * All copy lives here rather than in the page, so the quiet line and the loud
 * alert cannot describe the same state differently.
 */
const props = defineProps({
    // ISO 8601, or null when the snapshot has never built or the probe failed.
    refreshedAt: { type: String, default: null },
    // Server-rendered relative age ("21 hours ago"). The DB server writes
    // RefreshedAt with SYSDATETIME(); computing "ago" in the browser would be a
    // third clock.
    age: { type: String, default: null },
    ageHours: { type: Number, default: null },
    state: { type: String, default: 'unknown' },
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

// stale and failed are faults a person can act on; ok and unknown are not.
const isFault = computed(() => props.state === 'stale' || props.state === 'failed')
</script>

<template>
    <!-- ── Fault: stale or failed ─────────────────────────────────────────────
         Deliberately the loudest thing in the header, and the only part of it
         that uses amber. It names the time the figures ARE correct as at, so a
         reader can still use them, and says what to do. -->
    <div v-if="isFault"
        class="mx-auto flex max-w-2xl items-start gap-2.5 rounded-lg border border-amber-300/70 bg-amber-50
               px-3 py-2 text-left text-xs text-amber-900
               dark:border-amber-300/40 dark:bg-amber-400/10 dark:text-amber-100"
        role="status">
        <i class="fas fa-triangle-exclamation mt-0.5 flex-shrink-0" aria-hidden="true"></i>

        <p v-if="state === 'stale'">
            <span class="font-semibold">The nightly refresh has not run since {{ exact }}</span>
            <span v-if="ageHours"> — {{ ageHours }} hours ago</span>.
            These figures are correct as at that time but are no longer being updated. Contact IT.
        </p>

        <p v-else>
            <span class="font-semibold">The last refresh attempt failed.</span>
            These figures are from {{ exact }}<span v-if="age"> ({{ age }})</span> and still
            reconcile to the summary, but they will not update until the refresh succeeds.
            Contact IT.
        </p>
    </div>

    <!-- ── Normal, and "we cannot tell" ───────────────────────────────────────
         One quiet centred line under the page header, matching the subtitle and
         money note above it. A bordered strip was tried here on 2026-10-02 and
         removed the same day — it read as a fifth KPI card above four real
         ones. -->
    <p v-else class="flex flex-wrap items-center justify-center gap-x-2 text-xs text-tx-subtle"
        :title="refreshedAt || undefined">
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
