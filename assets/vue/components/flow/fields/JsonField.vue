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
      class="jf-editor overflow-hidden rounded-xl ring-1 transition-all duration-200"
      :class="[
        validationError
          ? 'ring-error/30 hover:ring-error/40'
          : 'ring-base-content/6 hover:ring-base-content/10 focus-within:ring-2 focus-within:ring-primary/25',
      ]"
    >
      <JsonEditorVue
        v-model="editorValue"
        v-model:mode="editorMode"
        :read-only="field.disabled || field.readOnly"
        :main-menu-bar="false"
        :navigation-bar="false"
        :status-bar="false"
        :tab-size="2"
        :on-render-menu="onRenderMenu"
        class="jf-themed"
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
import { computed, ref, watch } from 'vue';
import JsonEditorVue from 'json-editor-vue';
import { Mode } from 'vanilla-jsoneditor';
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
const editorMode = ref(Mode.text);

const editorValue = ref<unknown>(props.modelValue ?? null);

const placeholder = computed(() => {
  if (props.field.placeholder) return props.field.placeholder;
  return Array.isArray(props.field.default) ? '[\n  \n]' : '{\n  \n}';
});

const jsonKind = computed(() => {
  const value = props.modelValue;
  if (Array.isArray(value)) return 'array';
  if (value === null) return 'null';
  switch (typeof value) {
    case 'object': return 'object';
    case 'string': return 'string';
    case 'number': return 'number';
    case 'boolean': return 'boolean';
    default: return 'json';
  }
});

// Strip the menu completely
function onRenderMenu(): never[] {
  return [];
}

// Sync from parent → editor
watch(
  () => props.modelValue,
  (value) => {
    editorValue.value = value ?? null;
    validationError.value = null;
    emit('validation', null);
  }
);

// Sync from editor → parent
watch(editorValue, (value) => {
  if (typeof value === 'string') {
    const trimmed = value.trim();
    if (trimmed === '') {
      validationError.value = null;
      emit('validation', null);
      emit('update:modelValue', null);
      return;
    }
    try {
      const parsed = JSON.parse(trimmed);
      validationError.value = null;
      emit('validation', null);
      emit('update:modelValue', parsed);
    } catch {
      validationError.value = 'Invalid JSON';
      emit('validation', 'Invalid JSON');
    }
  } else {
    validationError.value = null;
    emit('validation', null);
    emit('update:modelValue', value);
  }
});
</script>

<style>
/* ── Minimal theme for the embedded JSON editor ── */
.jf-themed {
  /* Reset all borders */
  --jse-main-border: none;

  /* Background & text */
  --jse-background-color: transparent;
  --jse-text-color: oklch(var(--bc));

  /* Theme accent */
  --jse-theme-color: oklch(var(--p));
  --jse-theme-color-highlight: oklch(var(--p) / 0.15);

  /* Panels (hidden, but just in case) */
  --jse-panel-background: oklch(var(--b2) / 0.5);
  --jse-panel-border: none;

  /* Syntax colors */
  --jse-key-color: oklch(var(--bc) / 0.75);
  --jse-value-color: oklch(var(--bc) / 0.65);
  --jse-value-color-string: oklch(0.55 0.15 155);
  --jse-value-color-number: oklch(0.6 0.15 250);
  --jse-value-color-boolean: oklch(0.55 0.15 290);
  --jse-value-color-null: oklch(var(--bc) / 0.4);
  --jse-value-color-url: oklch(0.55 0.15 155);
  --jse-delimiter-color: oklch(var(--bc) / 0.3);

  /* Selection */
  --jse-selection-background-color: oklch(var(--p) / 0.1);
  --jse-selection-background-inactive-color: oklch(var(--p) / 0.05);
  --jse-hover-background-color: oklch(var(--bc) / 0.03);
  --jse-active-line-background-color: oklch(var(--bc) / 0.03);

  /* Context menu */
  --jse-context-menu-background: oklch(var(--b1));
  --jse-context-menu-background-highlight: oklch(var(--b2));
  --jse-context-menu-color: oklch(var(--bc));
  --jse-context-menu-separator-color: oklch(var(--bc) / 0.08);

  /* Tags */
  --jse-tag-background: oklch(var(--b2) / 0.6);
  --jse-tag-color: oklch(var(--bc) / 0.6);

  /* Edit outline */
  --jse-edit-outline: 2px solid oklch(var(--p) / 0.4);

  /* Collapsed items */
  --jse-collapsed-items-background-color: oklch(var(--b2) / 0.4);
  --jse-collapsed-items-selected-background-color: oklch(var(--p) / 0.08);
  --jse-collapsed-items-link-color: oklch(var(--bc) / 0.5);
  --jse-collapsed-items-link-color-highlight: oklch(var(--p));

  /* Search */
  --jse-search-match-color: oklch(var(--wa) / 0.2);
  --jse-search-match-outline: 1px solid oklch(var(--wa) / 0.4);
  --jse-search-match-active-color: oklch(var(--wa) / 0.35);
  --jse-search-match-active-outline: 1px solid oklch(var(--wa) / 0.6);
}

/* Size constraints */
.jf-editor .jse-main {
  min-height: 220px;
  max-height: 500px;
  border: none !important;
}

/* Remove internal borders in text mode */
.jf-editor .jse-text-mode {
  border: none !important;
}

/* Clean up tree mode spacing */
.jf-editor .jse-tree-mode {
  border: none !important;
}

/* ── Dark mode ── */
:where([data-theme="dark"]) .jf-themed {
  --jse-key-color: oklch(var(--bc) / 0.85);
  --jse-value-color: oklch(var(--bc) / 0.7);
  --jse-value-color-string: oklch(0.72 0.15 155);
  --jse-value-color-number: oklch(0.75 0.15 250);
  --jse-value-color-boolean: oklch(0.7 0.15 290);
  --jse-value-color-null: oklch(var(--bc) / 0.45);
  --jse-delimiter-color: oklch(var(--bc) / 0.35);
  --jse-hover-background-color: oklch(var(--bc) / 0.05);
  --jse-active-line-background-color: oklch(var(--bc) / 0.05);
  --jse-context-menu-background: oklch(var(--b2));
  --jse-context-menu-background-highlight: oklch(var(--bc) / 0.1);
}
</style>
