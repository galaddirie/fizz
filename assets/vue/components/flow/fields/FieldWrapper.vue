<template>
  <div class="field-wrapper">
    <div v-if="isSlotField">
      <SlotField :field="field" />
    </div>

    <div v-else-if="mode === 'literal' && uiComponent !== 'default'">
      <component
        :is="componentMap[uiComponent as keyof typeof componentMap]"
        :modelValue="modelValue"
        @update:modelValue="handleChange"
        @validation="handleValidation"
        :field="field"
        :nodeId="nodeId"
        :showLabel="false"
      />
    </div>

    <div v-else-if="mode === 'literal'">
      <textarea
        class="w-full min-h-[100px] resize-y rounded-xl bg-base-200/30 px-3.5 py-2.5 font-mono text-sm leading-relaxed text-base-content outline-none ring-1 ring-base-content/[0.06] transition-all duration-200 placeholder:text-base-content/30 hover:ring-base-content/10 focus:bg-base-100 focus:ring-2 focus:ring-primary/25"
        :value="typeof modelValue === 'object' ? JSON.stringify(modelValue, null, 2) : String(modelValue ?? '')"
        @input="handleTextareaChange(($event.target as HTMLTextAreaElement).value)"
        :disabled="field.disabled"
        :readonly="field.readOnly"
      ></textarea>
      <p v-if="field.description" class="mt-1.5 text-[11px] leading-relaxed text-base-content/40">
        {{ field.description }}
      </p>
    </div>

    <div v-else class="space-y-2">
      <textarea
        class="w-full min-h-[100px] resize-y rounded-xl bg-base-200/30 px-3.5 py-2.5 font-mono text-sm leading-relaxed text-base-content outline-none ring-1 ring-base-content/[0.06] transition-all duration-200 placeholder:text-base-content/30 hover:ring-base-content/10 focus:bg-base-100 focus:ring-2 focus:ring-primary/25"
        :value="typeof modelValue === 'object' ? JSON.stringify(modelValue, null, 2) : String(modelValue ?? '')"
        @input="handleTextareaChange(($event.target as HTMLTextAreaElement).value)"
        placeholder="{{ '{{' }} expression {{ '}}' }}"
        :disabled="field.disabled"
        :readonly="field.readOnly"
      ></textarea>
      <p v-if="field.description" class="text-[11px] leading-relaxed text-base-content/40">
        {{ field.description }}
      </p>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed } from 'vue';

import StringField from './StringField.vue';
import NumberField from './NumberField.vue';
import JsonField from './JsonField.vue';
import SelectField from './SelectField.vue';
import SearchField from './SearchField.vue';
import SlotField from './SlotField.vue';

import type { ConfigField } from '@/types/configSchema';

const props = defineProps<{
  modelValue: unknown;
  mode: 'literal' | 'expression';
  field: ConfigField;
  nodeId: string;
}>();

const emit = defineEmits(['update:modelValue', 'validation']);

const componentMap: Record<string, any> = {
  'string': StringField,
  'text': StringField,
  'number': NumberField,
  'json': JsonField,
  'select': SelectField,
  'search': SearchField,
  // Fallbacks:
  'default': StringField
};

const uiComponent = computed(() => {
  const comp = props.field?.ui?.component || props.field?.type || 'string';
  return componentMap[comp] ? comp : 'default';
});

const isSlotField = computed(() => props.field?.ui?.component === 'slot');

const handleChange = (val: unknown) => {
  emit('update:modelValue', val);
};

const handleValidation = (error: string | null) => {
  emit('validation', error);
};

const handleTextareaChange = (val: string) => {
  emit('validation', null);
  handleChange(val);
};
</script>
