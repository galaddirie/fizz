<template>
  <div>
    <div class="mb-2 flex items-center justify-between gap-3">
      <label v-if="showLabel && field.label" class="block text-xs font-medium text-base-content/60">
        {{ field.label }}
      </label>

      <div class="ml-auto flex items-center gap-2">
        <span
          class="rounded-full px-2 py-1 text-[10px] font-semibold tracking-wide uppercase"
          :class="validationError ? 'bg-error/10 text-error/80' : 'bg-base-200/70 text-base-content/45'"
        >
          {{ validationError || jsonKind }}
        </span>
      </div>
    </div>

    <div
      class="overflow-hidden rounded-xl ring-1 transition-all duration-200"
      :class="[
        validationError
          ? 'ring-error/30 hover:ring-error/40'
          : 'ring-base-content/6 hover:ring-base-content/10 focus-within:ring-2 focus-within:ring-primary/25',
      ]"
    >
      <JsonFrame
        :modelValue="modelValue"
        default-view="json"
        :read-only="field.disabled || field.readOnly"
        @update:modelValue="value => emit('update:modelValue', value)"
        @validation="handleValidation"
      />
    </div>

    <div class="mt-2 flex items-start justify-between gap-3">
      <p v-if="validationError" class="text-[11px] leading-relaxed text-error/80">
        Enter valid JSON before saving.
      </p>
      <p v-else-if="field.description" class="text-[11px] leading-relaxed text-base-content/40">
        {{ field.description }}
      </p>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed, ref } from 'vue';
import JsonFrame from '@/components/ui/data-viewer/JsonFrame.vue';
import type { ConfigField } from '@/types/configSchema';

const props = defineProps<{
  modelValue: unknown;
  field: ConfigField;
  nodeId: string;
  showLabel?: boolean;
}>();

const emit = defineEmits<{
  (e: 'update:modelValue', value: unknown): void;
  (e: 'validation', error: string | null): void;
}>();

const showLabel = computed(() => props.showLabel ?? true);
const validationError = ref<string | null>(null);

const jsonKind = computed(() => {
  const value = props.modelValue;
  if (Array.isArray(value)) return 'array';
  if (value === null) return 'null';

  switch (typeof value) {
    case 'object':
      return 'object';
    case 'string':
      return 'string';
    case 'number':
      return 'number';
    case 'boolean':
      return 'boolean';
    default:
      return 'json';
  }
});

function handleValidation(error: string | null) {
  validationError.value = error;
  emit('validation', error);
}
</script>
