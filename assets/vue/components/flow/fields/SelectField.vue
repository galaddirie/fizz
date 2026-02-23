<template>
  <div class="form-control w-full">
    <label v-if="field.label" class="label">
      <span class="label-text font-medium">{{ field.label }}</span>
    </label>
    
    <select 
      class="select select-bordered w-full font-mono text-sm" 
      :value="selectedValue"
      @change="handleSelect(($event.target as HTMLSelectElement).value)"
      :disabled="field.disabled || isLoading"
    >
      <option disabled value="">
        {{ isLoading ? 'Loading...' : 'Select an option...' }}
      </option>
      <option v-for="opt in options" :key="String(opt.value)" :value="JSON.stringify(opt.value)">
        {{ opt.label || opt.value }}
      </option>
    </select>
    
    <label v-if="field.description" class="label">
      <span class="label-text-alt text-base-content/70">{{ field.description }}</span>
    </label>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue';
import { useLiveVue } from 'live_vue';

import type { ConfigField } from '@/types/configSchema';

const props = defineProps<{
  modelValue: unknown;
  field: ConfigField;
  nodeId: string;
}>();

const emit = defineEmits(['update:modelValue']);

const live = useLiveVue();

const resolvedOptions = ref<Array<{ label: string; value: unknown }>>([]);
const isLoading = ref(false);

const options = computed(() => {
  // Static options from schema enum
  if (props.field?.enum && props.field.enum.length > 0) {
    return props.field.enum.map((v: unknown) => ({ label: String(v), value: v }));
  }
  // Static options from ui.options
  if (props.field?.ui?.options && props.field.ui.options.length > 0) {
    return props.field.ui.options;
  }
  // Resolver-loaded options
  return resolvedOptions.value;
});

// For object values (like credential_ref), match by JSON string
const selectedValue = computed(() => {
  if (props.modelValue == null) return '';
  if (typeof props.modelValue === 'object') {
    return JSON.stringify(props.modelValue);
  }
  return JSON.stringify(props.modelValue);
});

function handleSelect(jsonValue: string) {
  try {
    const parsed = JSON.parse(jsonValue);
    emit('update:modelValue', parsed);
  } catch {
    emit('update:modelValue', jsonValue);
  }
}

// Auto-fetch options from resolver on mount
function fetchResolverOptions() {
  const resolver = props.field?.ui?.resolver;
  if (!resolver) return;

  isLoading.value = true;
  const params = props.field.ui?.params || {};

  try {
    live.pushEvent(
      'resolve_field_options',
      {
        field_key: props.field.key,
        node_id: props.nodeId,
        params,
        q: '',
      },
      (reply: any) => {
        isLoading.value = false;
        if (reply?.options) {
          resolvedOptions.value = reply.options.map((opt: any) => {
            const value = opt?.value ?? opt;
            const label =
              opt?.label ??
              opt?.display_name ??
              opt?.name ??
              String(opt?.value ?? opt?.id ?? '');

            return { label, value };
          });
        } else {
          resolvedOptions.value = [];
        }
      }
    );
  } catch (error) {
    isLoading.value = false;
    resolvedOptions.value = [];
    console.error('SelectField: failed to resolve options', error);
  }
}

onMounted(() => {
  if (props.field?.ui?.resolver) {
    fetchResolverOptions();
  }
});

watch(
  () => [props.nodeId, props.field?.key, props.field?.ui?.resolver, props.field?.ui?.params],
  (_newValues) => {
    if (props.field?.ui?.resolver) {
      fetchResolverOptions();
    }
  },
  { deep: true }
);
</script>
