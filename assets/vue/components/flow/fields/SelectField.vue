<template>
  <div>
    <label v-if="showLabel && field.label" class="mb-1.5 block text-xs font-medium text-base-content/60">
      {{ field.label }}
    </label>

    <div class="relative">
      <select
        class="w-full appearance-none rounded-xl bg-base-200/30 px-3.5 py-2.5 pr-10 text-sm text-base-content outline-none ring-1 ring-base-content/[0.06] transition-all duration-200 hover:ring-base-content/10 focus:bg-base-100 focus:ring-2 focus:ring-primary/25 disabled:pointer-events-none disabled:opacity-40"
        :value="selectedValue"
        @change="handleSelect(($event.target as HTMLSelectElement).value)"
        :disabled="field.disabled || isLoading"
      >
        <option disabled value="" class="text-base-content/30">
          {{ isLoading ? 'Loading\u2026' : 'Select an option\u2026' }}
        </option>
        <option v-for="opt in options" :key="String(opt.value)" :value="JSON.stringify(opt.value)">
          {{ opt.label || opt.value }}
        </option>
      </select>

      <div class="pointer-events-none absolute inset-y-0 right-0 flex items-center pr-3">
        <span v-if="isLoading" class="loading loading-spinner loading-xs text-base-content/30"></span>
        <ChevronUpDownIcon v-else class="h-4 w-4 text-base-content/25" />
      </div>
    </div>

    <p v-if="field.description" class="mt-1.5 text-[11px] leading-relaxed text-base-content/40">
      {{ field.description }}
    </p>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue';
import { useLiveVue } from 'live_vue';
import { ChevronUpDownIcon } from '@heroicons/vue/20/solid';

import type { ConfigField } from '@/types/configSchema';

const props = defineProps<{
  modelValue: unknown;
  field: ConfigField;
  nodeId: string;
  showLabel?: boolean;
}>();

const emit = defineEmits(['update:modelValue']);
const showLabel = computed(() => props.showLabel ?? true);

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
