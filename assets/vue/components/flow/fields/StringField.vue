<template>
  <div>
    <label v-if="showLabel && field.label" class="mb-1.5 block text-xs font-medium text-base-content/60">
      {{ field.label }}
    </label>

    <input
      type="text"
      class="w-full rounded-xl bg-base-200/30 px-3.5 py-2.5 text-sm text-base-content outline-none ring-1 ring-base-content/[0.06] transition-all duration-200 placeholder:text-base-content/30 hover:ring-base-content/10 focus:bg-base-100 focus:ring-2 focus:ring-primary/25 disabled:pointer-events-none disabled:opacity-40"
      :value="modelValue"
      @input="emit('update:modelValue', ($event.target as HTMLInputElement).value)"
      :placeholder="field.placeholder || 'Enter a value\u2026'"
      :disabled="field.disabled"
      :readonly="field.readOnly"
    />

    <p v-if="field.description" class="mt-1.5 text-[11px] leading-relaxed text-base-content/40">
      {{ field.description }}
    </p>
  </div>
</template>

<script setup lang="ts">
import { computed } from 'vue';

const props = defineProps<{
  modelValue: unknown;
  field: any;
  nodeId: string;
  showLabel?: boolean;
}>();

const emit = defineEmits(['update:modelValue']);
const showLabel = computed(() => props.showLabel ?? true);
</script>
