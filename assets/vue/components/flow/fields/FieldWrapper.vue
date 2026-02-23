<template>
  <div class="field-wrapper">
    <div v-if="mode === 'literal' && uiComponent !== 'default'">
      <component
        :is="componentMap[uiComponent as keyof typeof componentMap]"
        :modelValue="modelValue"
        @update:modelValue="handleChange"
        :field="field"
        :nodeId="nodeId"
        :showLabel="false"
      />
    </div>

    <div v-else-if="mode === 'literal'">
      <textarea
        class="textarea textarea-bordered w-full min-h-[100px] font-mono text-sm leading-relaxed"
        :value="typeof modelValue === 'object' ? JSON.stringify(modelValue, null, 2) : String(modelValue || '')"
        @input="handleChange(($event.target as HTMLTextAreaElement).value)"
        :disabled="field.disabled"
        :readonly="field.readOnly"
      ></textarea>
      <p v-if="field.description" class="text-base-content/70 mt-2 text-xs">
        {{ field.description }}
      </p>
    </div>

    <div v-else class="space-y-2">
      <textarea
        class="textarea textarea-bordered w-full min-h-[100px] font-mono text-sm leading-relaxed"
        :value="String(modelValue ?? '')"
        @input="handleChange(($event.target as HTMLTextAreaElement).value)"
        placeholder="{{ '{{' }} expression {{ '}}' }}"
        :disabled="field.disabled"
        :readonly="field.readOnly"
      ></textarea>
      <p v-if="field.description" class="text-base-content/70 text-xs">
        {{ field.description }}
      </p>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed } from 'vue';

import StringField from './StringField.vue';
import NumberField from './NumberField.vue';
import SelectField from './SelectField.vue';
import SearchField from './SearchField.vue';

import type { ConfigField } from '@/types/configSchema';

const props = defineProps<{
  modelValue: unknown;
  mode: 'literal' | 'expression';
  field: ConfigField;
  nodeId: string;
}>();

const emit = defineEmits(['update:modelValue']);

const componentMap: Record<string, any> = {
  'string': StringField,
  'text': StringField,
  'number': NumberField,
  'select': SelectField,
  'search': SearchField,
  // Fallbacks:
  'default': StringField
};

const uiComponent = computed(() => {
  const comp = props.field?.ui?.component || props.field?.type || 'string';
  return componentMap[comp] ? comp : 'default';
});

const handleChange = (val: unknown) => {
  emit('update:modelValue', val);
};
</script>
