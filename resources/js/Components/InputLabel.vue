<script setup>
defineProps({
    value: {
        type: String,
    },
});
</script>

<template>
    <label class="block text-sm font-medium text-tx-body">
        <span v-if="value">{{ value }}</span>
        <span v-else><slot /></span>
    </label>
</template>
