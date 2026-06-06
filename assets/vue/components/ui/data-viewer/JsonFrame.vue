<script setup lang="ts">
import { computed, ref, watch } from 'vue';
import {
  CheckIcon,
  DocumentDuplicateIcon,
} from '@heroicons/vue/24/outline';
import JsonEditorVue from 'json-editor-vue';
import {
  Mode,
  getFocusPath,
  type ContextMenuItem,
  type JSONEditorSelection,
} from 'vanilla-jsoneditor';
import {
  buildLiquidPath,
  formatJsonForClipboard,
  normalizeJsonPathSegments,
  type JsonPathSegment,
  type ViewMode,
} from './types';

interface Props {
  modelValue: unknown;
  rootPath?: string;
  maxHeight?: string;
  defaultView?: ViewMode;
  allowedModes?: ViewMode[];
  showModeToggle?: boolean;
  showCopyJson?: boolean;
  showCopyExpression?: boolean;
  readOnly?: boolean;
  emptyLabel?: string;
}

const props = withDefaults(defineProps<Props>(), {
  rootPath: '',
  maxHeight: '',
  defaultView: 'tree',
  allowedModes: () => ['tree', 'json', 'table'],
  showModeToggle: true,
  showCopyJson: false,
  showCopyExpression: false,
  readOnly: false,
  emptyLabel: 'No data available',
});

const emit = defineEmits<{
  (e: 'update:modelValue', value: unknown): void;
  (e: 'validation', error: string | null): void;
  (e: 'copy:expression', expression: string): void;
}>();

const modeMap: Record<ViewMode, Mode> = {
  tree: Mode.tree,
  json: Mode.text,
  table: Mode.table,
};

const modeMeta: { id: ViewMode; label: string; icon: string }[] = [
  { id: 'tree', label: 'Tree', icon: '{}' },
  { id: 'json', label: 'JSON', icon: '</>' },
  { id: 'table', label: 'Table', icon: '[]' },
];

const availableModes = computed(() =>
  modeMeta.filter(mode => props.allowedModes.includes(mode.id))
);

const initialMode = computed(() => {
  const nextMode = availableModes.value.find(mode => mode.id === props.defaultView);
  return nextMode?.id ?? availableModes.value[0]?.id ?? 'tree';
});

const editorValue = ref<unknown>(props.modelValue ?? null);
const editorMode = ref<Mode>(modeMap[initialMode.value]);
const validationError = ref<string | null>(null);
const copiedMessage = ref<string | null>(null);
const selectedSegments = ref<JsonPathSegment[]>([]);
let copyTimeout: ReturnType<typeof setTimeout> | null = null;

const hasValue = computed(() => !props.readOnly || props.modelValue !== undefined);
const showToolbarExpression = computed(() => props.showCopyExpression && !!props.rootPath);

const toolbarVisible = computed(() => {
  return (
    (props.showModeToggle && availableModes.value.length > 1) ||
    props.showCopyJson ||
    showToolbarExpression.value
  );
});

const selectedExpression = computed(() => {
  if (!props.rootPath) return null;
  return buildLiquidPath(props.rootPath, selectedSegments.value);
});

const currentExpression = computed(() => {
  if (!props.rootPath) return null;
  return selectedExpression.value ?? buildLiquidPath(props.rootPath, []);
});

const selectionHint = computed(() => {
  if (!selectedSegments.value.length) return 'Root';
  return currentExpression.value;
});

const containerStyle = computed(() => {
  if (!props.maxHeight) return {};
  return { maxHeight: props.maxHeight, '--json-frame-max-height': props.maxHeight };
});

watch(
  () => props.modelValue,
  value => {
    editorValue.value = value ?? null;
    validationError.value = null;
    selectedSegments.value = [];
    emit('validation', null);
  },
  { immediate: true }
);

watch(
  () => props.defaultView,
  () => {
    editorMode.value = modeMap[initialMode.value];
  }
);

watch(editorValue, value => {
  if (props.readOnly) return;

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

    return;
  }

  validationError.value = null;
  emit('validation', null);
  emit('update:modelValue', value);
});

function copyText(text: string, label: string) {
  navigator.clipboard.writeText(text);
  copiedMessage.value = label;

  if (copyTimeout) clearTimeout(copyTimeout);
  copyTimeout = setTimeout(() => {
    copiedMessage.value = null;
  }, 1500);
}

function handleCopyJson() {
  copyText(formatJsonForClipboard(props.modelValue), 'Copied JSON');
}

function copyExpression(expression: string) {
  copyText(expression, 'Copied expression');
  emit('copy:expression', expression);
}

function handleCopyExpression() {
  if (!currentExpression.value) return;
  copyExpression(currentExpression.value);
}

function resolveSegments(selection: JSONEditorSelection | undefined): JsonPathSegment[] {
  if (!selection || selection.type === 'text') return [];
  return normalizeJsonPathSegments(props.modelValue, getFocusPath(selection));
}

function handleSelect(selection: JSONEditorSelection | undefined) {
  selectedSegments.value = resolveSegments(selection);
}

function onRenderContextMenu(items: ContextMenuItem[], context: { selection: JSONEditorSelection | undefined }) {
  if (!props.showCopyExpression || !props.rootPath) return items;

  const expression = buildLiquidPath(props.rootPath, resolveSegments(context.selection));

  return [
    ...items,
    { type: 'separator' },
    {
      type: 'button',
      text: 'Copy expression',
      title: expression,
      onClick: () => copyExpression(expression),
    },
  ];
}

const renderContextMenu = onRenderContextMenu as unknown as (...args: any[]) => ContextMenuItem[];
</script>

<template>
  <div class="relative flex flex-col overflow-hidden" :style="containerStyle">
    <div
      v-if="toolbarVisible && hasValue"
      class="flex shrink-0 items-center justify-between gap-3 border-b border-base-200/60 px-2 py-1.5"
    >
      <div
        v-if="showModeToggle && availableModes.length > 1"
        class="flex items-center gap-0.5 rounded-md bg-base-200/40 p-0.5"
      >
        <button
          v-for="mode in availableModes"
          :key="mode.id"
          @click="editorMode = modeMap[mode.id]"
          :title="mode.label"
          :class="[
            'cursor-pointer rounded px-2.5 py-1 text-[11px] font-medium transition-all',
            editorMode === modeMap[mode.id]
              ? 'bg-base-100 text-base-content shadow-sm'
              : 'text-base-content/55 hover:text-base-content/75',
          ]"
        >
          <span class="mr-1 font-mono text-[10px] opacity-60">{{ mode.icon }}</span>
          {{ mode.label }}
        </button>
      </div>
      <div v-else class="min-h-6"></div>

      <div class="flex items-center gap-2">
        <span
          v-if="showToolbarExpression && rootPath"
          class="hidden max-w-64 truncate font-mono text-[10px] text-base-content/35 md:block"
          :title="selectionHint || undefined"
        >
          {{ selectionHint }}
        </span>

        <button
          v-if="showCopyJson"
          @click="handleCopyJson"
          class="flex items-center gap-1 rounded-md border border-base-300/50 bg-base-100 px-2 py-1 text-[11px] font-medium text-base-content/60 transition-all hover:border-base-300 hover:text-base-content/80"
        >
          <CheckIcon v-if="copiedMessage === 'Copied JSON'" class="size-3 text-success" />
          <DocumentDuplicateIcon v-else class="size-3" />
          JSON
        </button>

        <button
          v-if="showToolbarExpression && rootPath"
          @click="handleCopyExpression"
          class="flex items-center gap-1 rounded-md border border-base-300/50 bg-base-100 px-2 py-1 text-[11px] font-medium text-base-content/60 transition-all hover:border-base-300 hover:text-base-content/80"
        >
          <CheckIcon v-if="copiedMessage === 'Copied expression'" class="size-3 text-success" />
          <DocumentDuplicateIcon v-else class="size-3" />
          Expression
        </button>
      </div>
    </div>

    <div v-if="hasValue" class="json-frame-editor min-h-0 flex-1 overflow-hidden bg-base-200/20">
      <JsonEditorVue
        v-model="editorValue"
        v-model:mode="editorMode"
        :read-only="readOnly"
        :main-menu-bar="false"
        :navigation-bar="false"
        :status-bar="false"
        :tab-size="2"
        :flatten-columns="true"
        :on-select="handleSelect"
        :on-render-context-menu="renderContextMenu"
        class="json-frame-themed"
      />
    </div>

    <div
      v-else
      class="flex min-h-40 items-center justify-center bg-base-200/20 px-4 py-8 text-sm text-base-content/45"
    >
      {{ emptyLabel }}
    </div>

    <Transition
      enter-active-class="transition-all duration-200 ease-out"
      enter-from-class="translate-y-2 opacity-0"
      enter-to-class="translate-y-0 opacity-100"
      leave-active-class="transition-all duration-150 ease-in"
      leave-from-class="translate-y-0 opacity-100"
      leave-to-class="translate-y-2 opacity-0"
    >
      <div
        v-if="copiedMessage"
        class="absolute right-3 bottom-3 rounded-lg bg-base-content px-3 py-1.5 text-[11px] font-medium text-base-100 shadow-lg"
      >
        {{ copiedMessage }}
      </div>
    </Transition>
  </div>
</template>

<style>
.json-frame-themed {
  --jse-main-border: none;
  --jse-background-color: transparent;
  --jse-text-color: oklch(var(--bc));
  --jse-theme-color: oklch(var(--p));
  --jse-theme-color-highlight: oklch(var(--p) / 0.15);
  --jse-panel-background: oklch(var(--b2) / 0.5);
  --jse-panel-border: none;
  --jse-key-color: oklch(var(--bc) / 0.75);
  --jse-value-color: oklch(var(--bc) / 0.65);
  --jse-value-color-string: oklch(0.55 0.15 155);
  --jse-value-color-number: oklch(0.6 0.15 250);
  --jse-value-color-boolean: oklch(0.55 0.15 290);
  --jse-value-color-null: oklch(var(--bc) / 0.4);
  --jse-value-color-url: oklch(0.55 0.15 155);
  --jse-delimiter-color: oklch(var(--bc) / 0.3);
  --jse-selection-background-color: oklch(var(--p) / 0.1);
  --jse-selection-background-inactive-color: oklch(var(--p) / 0.05);
  --jse-hover-background-color: oklch(var(--bc) / 0.03);
  --jse-active-line-background-color: oklch(var(--bc) / 0.03);
  --jse-context-menu-background: oklch(var(--b1));
  --jse-context-menu-background-highlight: oklch(var(--b2));
  --jse-context-menu-color: oklch(var(--bc));
  --jse-context-menu-separator-color: oklch(var(--bc) / 0.08);
  --jse-tag-background: oklch(var(--b2) / 0.6);
  --jse-tag-color: oklch(var(--bc) / 0.6);
  --jse-edit-outline: 2px solid oklch(var(--p) / 0.4);
  --jse-collapsed-items-background-color: oklch(var(--b2) / 0.4);
  --jse-collapsed-items-selected-background-color: oklch(var(--p) / 0.08);
  --jse-collapsed-items-link-color: oklch(var(--bc) / 0.5);
  --jse-collapsed-items-link-color-highlight: oklch(var(--p));
  --jse-search-match-color: oklch(var(--wa) / 0.2);
  --jse-search-match-outline: 1px solid oklch(var(--wa) / 0.4);
  --jse-search-match-active-color: oklch(var(--wa) / 0.35);
  --jse-search-match-active-outline: 1px solid oklch(var(--wa) / 0.6);
}

.json-frame-editor .jse-main {
  min-height: 220px;
  max-height: var(--json-frame-max-height, 500px);
  border: none !important;
}

.json-frame-editor .jse-text-mode,
.json-frame-editor .jse-tree-mode,
.json-frame-editor .jse-table-mode {
  border: none !important;
}

:where([data-theme="dark"]) .json-frame-themed {
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
