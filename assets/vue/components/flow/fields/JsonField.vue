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

        <button
          type="button"
          class="rounded-lg border border-base-content/10 px-2.5 py-1 text-[11px] font-medium text-base-content/55 transition-colors hover:border-base-content/20 hover:text-base-content/75 disabled:cursor-not-allowed disabled:opacity-35"
          :disabled="field.disabled || field.readOnly || draftValue.trim() === ''"
          @click="formatDraft"
        >
          Format
        </button>
      </div>
    </div>

    <textarea
      class="min-h-[220px] w-full resize-y rounded-xl bg-base-200/30 px-3.5 py-3 font-mono text-sm leading-relaxed text-base-content outline-none ring-1 transition-all duration-200 placeholder:text-base-content/30 focus:bg-base-100 focus:ring-2"
      :class="
        validationError
          ? 'ring-error/30 hover:ring-error/40 focus:ring-error/35'
          : 'ring-base-content/[0.06] hover:ring-base-content/10 focus:ring-primary/25'
      "
      :value="draftValue"
      :placeholder="placeholder"
      :disabled="field.disabled"
      :readonly="field.readOnly"
      spellcheck="false"
      @input="handleInput(($event.target as HTMLTextAreaElement).value)"
      @blur="formatDraft"
    ></textarea>

    <div class="mt-2 flex items-start justify-between gap-3">
      <p
        v-if="validationError"
        class="text-[11px] leading-relaxed text-error/80"
      >
        Enter valid JSON before saving.
      </p>
      <p
        v-else-if="field.description"
        class="text-[11px] leading-relaxed text-base-content/40"
      >
        {{ field.description }}
      </p>

      <p class="ml-auto shrink-0 text-[10px] font-medium tracking-wide text-base-content/30 uppercase">
        Structured Data
      </p>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed, ref, watch } from 'vue';

import type { ConfigField } from '@/types/configSchema';

const props = defineProps<{
  modelValue: unknown;
  field: ConfigField;
  nodeId: string;
  showLabel?: boolean;
}>();

const emit = defineEmits(['update:modelValue', 'validation']);

const showLabel = computed(() => props.showLabel ?? true);
const validationError = ref<string | null>(null);
const draftValue = ref(formatValue(props.modelValue));

const placeholder = computed(() => {
  if (props.field.placeholder) return props.field.placeholder;
  return Array.isArray(props.field.default) ? '[\n  \n]' : '{\n  \n}';
});

const jsonKind = computed(() => {
  const value = props.modelValue;

  if (Array.isArray(value)) return 'JSON array';
  if (value === null) return 'JSON null';

  switch (typeof value) {
    case 'object':
      return 'JSON object';
    case 'string':
      return 'JSON string';
    case 'number':
      return 'JSON number';
    case 'boolean':
      return 'JSON boolean';
    default:
      return 'JSON value';
  }
});

watch(
  () => props.modelValue,
  (value) => {
    draftValue.value = formatValue(value);
    validationError.value = null;
    emit('validation', null);
  },
  { immediate: true }
);

function formatValue(value: unknown) {
  if (value === undefined) return '';

  if (typeof value === 'string') {
    try {
      return JSON.stringify(JSON.parse(value), null, 2);
    } catch {
      return JSON.stringify(value, null, 2);
    }
  }

  try {
    return JSON.stringify(value, null, 2);
  } catch {
    return String(value ?? '');
  }
}

function setValidation(error: string | null) {
  validationError.value = error;
  emit('validation', error);
}

function updateFromDraft(raw: string) {
  const trimmed = raw.trim();

  if (trimmed === '') {
    setValidation(null);
    emit('update:modelValue', null);
    return;
  }

  try {
    const parsed = JSON.parse(raw);
    setValidation(null);
    emit('update:modelValue', parsed);
  } catch {
    setValidation('Invalid JSON');
  }
}

function handleInput(raw: string) {
  draftValue.value = raw;
  updateFromDraft(raw);
}

function formatDraft() {
  if (draftValue.value.trim() === '') {
    updateFromDraft('');
    return;
  }

  try {
    const parsed = JSON.parse(draftValue.value);
    draftValue.value = JSON.stringify(parsed, null, 2);
    setValidation(null);
    emit('update:modelValue', parsed);
  } catch {
    setValidation('Invalid JSON');
  }
}
</script>
