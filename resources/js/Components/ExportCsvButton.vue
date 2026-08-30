<script setup>
import { computed } from 'vue'

/**
 * "Export CSV" for the finance report pages.
 *
 * A PLAIN ANCHOR, never router.get(). Inertia would try to parse the CSV
 * response as a page payload and blank the screen; a normal browser navigation
 * lets Content-Disposition do its job and leaves the report open behind the
 * download.
 *
 * The server decides what the file contains — this only carries the filters the
 * page has already applied. When disabled it renders as an inert span rather
 * than a dead link, so a keyboard user is told why instead of activating
 * nothing.
 */
const props = defineProps({
    href:     { type: String,  default: null },
    rowCount: { type: Number,  default: 0 },
    // True while a filter/year change is in flight, or when the user has no
    // department mapping. See `disabled` below for why loading matters.
    busy:     { type: Boolean, default: false },
    hasAccess: { type: Boolean, default: true },
    label:    { type: String,  default: 'Export CSV' },
})

/**
 * Disabled covers all three bad states with no extra props:
 *   - no department mapping  -> there is nothing to export, ever
 *   - zero rows              -> also how an outage presents (empty result set)
 *   - a navigation in flight -> the filter controls already hold the NEW values
 *     while rowCount still describes the OLD response, so an export started now
 *     would carry the wrong scope and announce the wrong count. It also stops
 *     someone firing several overlapping downloads.
 */
const disabled = computed(() =>
    !props.href || !props.hasAccess || props.busy || props.rowCount === 0
)

const rowLabel = computed(() =>
    new Intl.NumberFormat('en-TT').format(props.rowCount)
)

const ariaLabel = computed(() => {
    if (!props.hasAccess) return 'Export unavailable: department access is not configured'
    if (props.busy)       return 'Export unavailable while the report is loading'
    if (props.rowCount === 0) return 'Export unavailable: no rows match the current filters'

    return `Export all ${rowLabel.value} matching rows as CSV`
})

const title = computed(() => {
    if (!props.hasAccess) return 'Department access is not configured for your account.'
    if (props.busy)       return 'Loading…'
    if (props.rowCount === 0) return 'No rows match the current filters.'

    return `Exports all ${rowLabel.value} matching rows, not just this page.`
})
</script>

<template>
    <!-- Icon AND text: an icon alone would not say what it does. -->
    <span v-if="disabled"
        :aria-label="ariaLabel" :title="title" aria-disabled="true"
        class="inline-flex items-center gap-1.5 text-xs font-medium text-tx-subtle opacity-40 cursor-not-allowed select-none">
        <i class="fas fa-file-csv"></i>
        {{ label }}
    </span>

    <a v-else
        :href="href" :aria-label="ariaLabel" :title="title"
        class="inline-flex items-center gap-1.5 rounded px-1.5 py-0.5 text-xs font-medium text-tx-subtle transition hover:text-amber-600 focus:outline-none focus-visible:ring-2 focus-visible:ring-amber-500/60 dark:hover:text-amber-300">
        <i class="fas fa-file-csv"></i>
        {{ label }}
    </a>
</template>
