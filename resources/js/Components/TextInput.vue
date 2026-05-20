<script setup>
import { onMounted, ref } from 'vue';

const model = defineModel({
    type: String,
    required: true,
});

const input = ref(null);

onMounted(() => {
    if (input.value.hasAttribute('autofocus')) {
        input.value.focus();
    }
});

defineExpose({ focus: () => input.value.focus() });
</script>

<template>
    <input
        class="rounded-md border-line-input bg-surface text-tx-primary shadow-sm
               focus:border-indigo-500 focus:ring-indigo-500
               placeholder-gray-400 dark:placeholder-gray-500"
        v-model="model"
        ref="input"
    />
</template>
