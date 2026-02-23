<template>
  <div class="relative">
    <label v-if="showLabel && field.label" class="mb-1.5 block text-xs font-medium text-base-content/60">
      {{ field.label }}
    </label>

    <div class="relative">
      <!-- Selected value display -->
      <div
        v-if="modelValue && !isEditing"
        class="group/selected flex w-full cursor-pointer items-center justify-between rounded-xl bg-base-200/30 px-3.5 py-2.5 ring-1 ring-base-content/[0.06] transition-all duration-200 hover:ring-base-content/10"
        @click="startEditing"
      >
        <span class="truncate text-sm text-base-content">{{ displayLabel }}</span>
        <button
          @click.stop="clearSelection"
          class="ml-2 shrink-0 rounded-lg p-0.5 text-base-content/20 transition-colors hover:bg-base-200/60 hover:text-base-content/60"
          title="Clear selection"
        >
          <XMarkIcon class="h-3.5 w-3.5" />
        </button>
      </div>

      <!-- Search input -->
      <div v-else class="relative">
        <div class="pointer-events-none absolute inset-y-0 left-0 flex items-center pl-3.5">
          <MagnifyingGlassIcon class="h-3.5 w-3.5 text-base-content/25" />
        </div>
        <input
          ref="searchInput"
          type="text"
          class="w-full rounded-xl bg-base-200/30 py-2.5 pl-9 pr-9 text-sm text-base-content outline-none ring-1 ring-base-content/[0.06] transition-all duration-200 placeholder:text-base-content/30 hover:ring-base-content/10 focus:bg-base-100 focus:ring-2 focus:ring-primary/25"
          v-model="searchQuery"
          :placeholder="modelValue ? displayLabel : (field.placeholder || 'Search\u2026')"
          :disabled="field.disabled"
          :readonly="field.readOnly"
          @focus="isOpen = true"
          @blur="handleBlur"
        />
        <div class="absolute inset-y-0 right-0 flex items-center pr-3">
          <span v-if="isLoading" class="loading loading-spinner loading-xs text-base-content/30"></span>
          <button
            v-else-if="searchQuery"
            @click="searchQuery = ''"
            class="rounded-md p-0.5 text-base-content/25 transition-colors hover:text-base-content/60"
          >
            <XMarkIcon class="h-3.5 w-3.5" />
          </button>
        </div>
      </div>

      <!-- Dropdown -->
      <Transition
        enter-active-class="transition duration-150 ease-out"
        enter-from-class="scale-[0.98] opacity-0"
        enter-to-class="scale-100 opacity-100"
        leave-active-class="transition duration-100 ease-in"
        leave-from-class="scale-100 opacity-100"
        leave-to-class="scale-[0.98] opacity-0"
      >
        <ul
          v-show="isOpen && !field.disabled && !field.readOnly"
          class="absolute z-50 mt-1.5 w-full overflow-auto rounded-xl bg-base-100 shadow-lg ring-1 ring-base-content/[0.08]"
          style="max-height: 15rem"
          @mousedown.prevent
        >
          <li v-if="isLoading && options.length === 0" class="flex items-center justify-center px-4 py-6">
            <span class="loading loading-dots loading-sm text-base-content/20"></span>
          </li>
          <li v-else-if="options.length === 0" class="px-4 py-6 text-center text-xs text-base-content/30">
            No results found
          </li>
          <li
            v-for="(opt, idx) in options"
            :key="String(opt.value)"
            @click="selectOption(opt)"
            class="cursor-pointer px-3.5 py-2.5 transition-colors hover:bg-primary/5"
            :class="idx < options.length - 1 ? 'border-b border-base-content/[0.03]' : ''"
          >
            <div class="flex items-center justify-between gap-3">
              <span class="text-sm font-medium text-base-content">{{ opt.label }}</span>
              <div v-if="opt.meta" class="flex shrink-0 gap-1">
                <span
                  v-for="(meta, mIdx) in opt.meta"
                  :key="mIdx"
                  class="rounded-full bg-base-200/60 px-2 py-0.5 text-[9px] font-semibold text-base-content/45"
                >
                  {{ meta.value }}
                </span>
              </div>
            </div>
            <p v-if="opt.description" class="mt-0.5 text-[11px] leading-snug text-base-content/35">
              {{ opt.description }}
            </p>
          </li>
        </ul>
      </Transition>
    </div>

    <p v-if="field.description" class="mt-1.5 text-[11px] leading-relaxed text-base-content/40">
      {{ field.description }}
    </p>
  </div>
</template>

<script setup lang="ts">
import { ref, computed, watch, nextTick } from 'vue';
import { watchDebounced } from '@vueuse/core';
import { useLiveVue } from 'live_vue';
import { MagnifyingGlassIcon, XMarkIcon } from '@heroicons/vue/20/solid';

import type { ConfigField } from '@/types/configSchema';

const props = defineProps<{
  modelValue: unknown;
  field: ConfigField;
  nodeId: string;
  showLabel?: boolean;
}>();

const emit = defineEmits(['update:modelValue']);

const live = useLiveVue();
const showLabel = computed(() => props.showLabel ?? true);

interface MetaBadge {
  value: string;
  color?: string;
  key?: string;
  format?: string;
}

interface MappedOption {
  value: string | number;
  label: string;
  description?: string;
  meta?: MetaBadge[];
  raw?: unknown;
}

const searchQuery = ref('');
const options = ref<MappedOption[]>([]);
const isLoading = ref(false);
const isOpen = ref(false);
const isEditing = ref(false);
const searchInput = ref<HTMLInputElement | null>(null);

const uiConfig = computed(() => props.field.ui);
const mappingConfig = computed(() => uiConfig.value?.responseConfig?.mapping || {});

// Extract label for current value (if object)
const displayLabel = computed(() => {
  if (!props.modelValue) return '';

  if (typeof props.modelValue === 'object') {
     // Try to find label in the same shape as mapping
     const labelPath = mappingConfig.value?.label || 'label';
     // Simplified extraction for the selected value display
     if (labelPath.startsWith('$.') || !labelPath.includes('.')) {
       const key = labelPath.replace('$.', '');
       return (props.modelValue as any)[key] || 'Selected Item';
     }
  }
  return String(props.modelValue);
});

const startEditing = () => {
  isEditing.value = true;
  searchQuery.value = '';
  isOpen.value = true;
  fetchOptions('');
  nextTick(() => {
    searchInput.value?.focus();
  });
};

const handleBlur = () => {
  // Delay slightly to allow click event on dropdown to fire
  setTimeout(() => {
    isOpen.value = false;
    isEditing.value = false;
  }, 200);
};

const clearSelection = () => {
  emit('update:modelValue', null);
  startEditing();
};

const selectOption = (opt: MappedOption) => {
  emit('update:modelValue', opt.value);
  isOpen.value = false;
  isEditing.value = false;
  searchQuery.value = '';
};

const mapResults = (rawResults: any[]): MappedOption[] => {
  if (!Array.isArray(rawResults)) return [];

  return rawResults.map(item => {
    try {
      // Evaluate JSONPaths for each configured field mapping
      const extract = (path: string | undefined): any => {
        if (!path) return undefined;
        if (path === '$') return item;
        // Handle dot notation for nested properties
        const pathParts = path.replace(/^\$\./, '').split('.');
        let current: any = item;
        for (const part of pathParts) {
          if (current === null || current === undefined || typeof current !== 'object') {
            return undefined;
          }
          current = current[part];
        }
        return current;
      };

      const value = extract(mappingConfig.value.value || 'value');
      const label = extract(mappingConfig.value.label || 'label');
      const description = extract(mappingConfig.value.description);

      const meta = (mappingConfig.value.meta || []).map((m: any) => ({
        key: m.key,
        value: String(extract(m.value) || ''),
        format: m.format || 'badge'
      }));

      return { value, label: String(label || value), description, meta, raw: item };
    } catch (e) {
      console.error('Failed to map search result', item, e);
      return { value: item, label: 'Error Mapping', raw: item };
    }
  });
};

const fetchOptions = (query: string) => {
  if (!uiConfig.value?.resolver) {
    console.warn('SearchField: No resolver configured');
    return;
  }

  isLoading.value = true;

  try {
    live.pushEvent(
      'resolve_field_options',
      {
        node_id: props.nodeId,
        field_key: props.field.key,
        params: uiConfig.value.params || {},
        q: query
      },
      (reply: any) => {
        isLoading.value = false;
        if (reply?.options) {
          options.value = mapResults(reply.options);
        } else {
          options.value = [];
        }
      }
    );
  } catch (error) {
    isLoading.value = false;
    options.value = [];
    console.error('SearchField: failed to resolve options', error);
  }
};

watchDebounced(
  searchQuery,
  (newQuery) => {
    if (isOpen.value && isEditing.value) {
      fetchOptions(newQuery);
    }
  },
  { debounce: 300 }
);

// Initial fetch if empty but focused and options empty
watch(isOpen, (newVal) => {
  if (newVal && options.value.length === 0 && isEditing.value) {
    fetchOptions(searchQuery.value);
  }
});
</script>
