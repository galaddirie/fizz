<template>
  <div class="form-control w-full relative">
    <label v-if="field.label" class="label">
      <span class="label-text font-medium">{{ field.label }}</span>
    </label>
    
    <div class="relative">
      <!-- Read-only view when a value is selected -->
      <div v-if="modelValue && !isEditing" class="relative">
        <div class="input input-bordered w-full font-mono text-sm flex items-center pr-10 cursor-pointer bg-base-100" @click="startEditing">
          <span class="truncate">{{ displayLabel }}</span>
        </div>
        <button 
          @click="clearSelection" 
          class="absolute inset-y-0 right-0 px-3 flex items-center text-base-content/50 hover:text-base-content"
          title="Clear selection"
        >
          <XMarkIcon class="w-5 h-5" />
        </button>
      </div>

      <!-- Search Input when editing -->
      <div v-else class="relative">
        <div class="absolute inset-y-0 left-0 pl-3 flex items-center pointer-events-none">
          <MagnifyingGlassIcon class="w-4 h-4 text-base-content/50" />
        </div>
        <input 
          ref="searchInput"
          type="text" 
          class="input input-bordered w-full font-mono text-sm pl-9 pr-10" 
          v-model="searchQuery"
          :placeholder="modelValue ? displayLabel : (field.placeholder || 'Search...')"
          :disabled="field.disabled"
          :readonly="field.readOnly"
          @focus="isOpen = true"
          @blur="handleBlur"
        />
        <div v-if="isLoading" class="absolute inset-y-0 right-0 pr-3 flex items-center">
          <span class="loading loading-spinner loading-xs text-primary"></span>
        </div>
        <button 
          v-else-if="searchQuery" 
          @click="searchQuery = ''" 
          class="absolute inset-y-0 right-0 pr-3 flex items-center text-base-content/50 hover:text-base-content"
        >
          <XMarkIcon class="w-4 h-4" />
        </button>
      </div>
      
      <!-- Dropdown -->
      <ul 
        v-show="isOpen && !field.disabled && !field.readOnly" 
        class="absolute z-50 w-full mt-1 bg-base-100 rounded-md shadow-xl max-h-60 overflow-auto border border-base-300 left-0"
        @mousedown.prevent
      >
        <li v-if="isLoading && options.length === 0" class="p-4 text-sm text-center text-base-content/50">
          Loading...
        </li>
        <li v-else-if="options.length === 0" class="p-4 text-sm text-center text-base-content/50">
          No results found
        </li>
        <li 
          v-for="opt in options" 
          :key="opt.value" 
          @click="selectOption(opt)"
          class="px-4 py-2 hover:bg-base-200 cursor-pointer flex flex-col gap-1 border-b border-base-200 last:border-b-0"
        >
          <div class="flex items-center justify-between">
            <span class="font-medium text-sm">{{ opt.label }}</span>
            <div v-if="opt.meta" class="flex gap-1">
              <span 
                v-for="(meta, idx) in opt.meta" 
                :key="idx"
                class="badge badge-sm"
                :class="meta.color ? `badge-${meta.color}` : 'badge-ghost'"
              >
                {{ meta.value }}
              </span>
            </div>
          </div>
          <span v-if="opt.description" class="text-xs text-base-content/70">{{ opt.description }}</span>
        </li>
      </ul>
    </div>
    
    <label v-if="field.description" class="label">
      <span class="label-text-alt text-base-content/70">{{ field.description }}</span>
    </label>
  </div>
</template>

<script setup lang="ts">
import { ref, computed, watch, onMounted, nextTick, inject } from 'vue';
import { watchDebounced } from '@vueuse/core';
import { MagnifyingGlassIcon, XMarkIcon } from '@heroicons/vue/20/solid';

import type { ConfigField } from '@/types/configSchema';

const props = defineProps<{
  modelValue: unknown;
  field: ConfigField;
  nodeId: string;
}>();

const emit = defineEmits(['update:modelValue']);

// Injection from WorkflowEditor for liveview event pushing
const pushEvent = inject('pushEvent') as (event: string, payload: any, callback?: (reply: any) => void) => void;

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
  if (!pushEvent || !uiConfig.value?.resolver) {
    console.warn('SearchField: No resolver configured or pushEvent not available');
    return;
  }

  isLoading.value = true;
  
  pushEvent('resolve_field_options', {
    resolver: uiConfig.value.resolver,
    params: uiConfig.value.params || {},
    q: query
  }, (reply: any) => {
    isLoading.value = false;
    if (reply?.options) {
      options.value = mapResults(reply.options);
    } else {
      options.value = [];
    }
  });
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
