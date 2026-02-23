<template>
  <div class="field-wrapper mb-4 border-l-2 border-transparent hover:border-base-300 pl-2 -ml-[10px] transition-colors relative group">
    
    <!-- Mode Toggle Button (appears on hover) -->
    <button 
      v-if="!field.disabled && !field.readOnly"
      @click="toggleMode"
      class="absolute -left-[26px] top-9 text-base-content/30 hover:text-primary transition-colors opacity-0 group-hover:opacity-100 z-10"
      :class="{'text-primary opacity-100': isExpressionMode}"
      :title="isExpressionMode ? 'Switch to Literal Mode' : 'Switch to Expression Mode'"
    >
      <CodeBracketIcon v-if="!isExpressionMode" class="w-4 h-4" />
      <Bars3BottomLeftIcon v-else class="w-4 h-4" />
    </button>
    
    <!-- Badge indicator for expression mode -->
    <div v-if="field.label && isExpressionMode" class="absolute -top-1 right-2 pointer-events-none z-10">
      <span class="text-[10px] font-mono font-bold text-primary bg-primary/10 px-1.5 py-0.5 rounded uppercase tracking-wider">Expr</span>
    </div>

    <!-- Underlying Specific Component OR Expression Editor -->
    <div v-if="!isExpressionMode && uiComponent !== 'default'">
      <component 
        :is="componentMap[uiComponent as keyof typeof componentMap]" 
        :modelValue="modelValue"
        @update:modelValue="handleChange"
        :field="field"
        :nodeId="nodeId"
      />
    </div>
    <div v-else-if="!isExpressionMode">
        <textarea 
          class="textarea textarea-bordered w-full font-mono text-sm min-h-[100px] leading-relaxed" 
          :value="typeof modelValue === 'object' ? JSON.stringify(modelValue, null, 2) : String(modelValue || '')"
          @input="handleChange(($event.target as HTMLTextAreaElement).value)"
          :disabled="field.disabled"
          :readonly="field.readOnly"
        ></textarea>
    </div>
    <div v-else>
      <div class="form-control w-full">
        <label v-if="field.label" class="label">
          <span class="label-text font-medium">{{ field.label }}</span>
        </label>
        
        <textarea 
          class="textarea textarea-bordered w-full font-mono text-sm min-h-[100px] leading-relaxed" 
          :value="String(modelValue ?? '')"
          @input="handleChange(($event.target as HTMLTextAreaElement).value)"
          placeholder="{{ '{{' }} expression {{ '}}' }}"
          :disabled="field.disabled"
          :readonly="field.readOnly"
        ></textarea>
        
        <label v-if="field.description" class="label">
          <span class="label-text-alt text-base-content/70">{{ field.description }}</span>
        </label>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed } from 'vue';
import { CodeBracketIcon, Bars3BottomLeftIcon } from '@heroicons/vue/20/solid';

import StringField from './StringField.vue';
import NumberField from './NumberField.vue';
import SelectField from './SelectField.vue';
import SearchField from './SearchField.vue';

import type { ConfigField } from '@/types/configSchema';

const props = defineProps<{
  modelValue: unknown;
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

const isExpressionMode = computed(() => {
  return typeof props.modelValue === 'string' && 
         (props.modelValue.includes('{{') || props.modelValue.includes('{%'));
});

const toggleMode = () => {
  if (isExpressionMode.value) {
    emit('update:modelValue', props.field.default ?? '');
  } else {
    emit('update:modelValue', `{{ ${props.field.key || 'expression'} }}`);
  }
};

const handleChange = (val: unknown) => {
  emit('update:modelValue', val);
};
</script>
