<template>
  <div class="form-control w-full">
    <label v-if="field.label" class="label">
      <span class="label-text font-medium">{{ field.label }}</span>
    </label>
    
    <input 
      type="number" 
      class="input input-bordered w-full font-mono text-sm" 
      :value="modelValue"
      @input="updateValue(($event.target as HTMLInputElement).value)"
      :min="field.minimum"
      :max="field.maximum"
      :step="field.multipleOf || 'any'"
      :placeholder="field.placeholder"
      :disabled="field.disabled"
      :readonly="field.readOnly"
    />
    
    <label v-if="field.description" class="label">
      <span class="label-text-alt text-base-content/70">{{ field.description }}</span>
    </label>
  </div>
</template>

<script setup lang="ts">
import { computed } from 'vue';

const props = defineProps<{
  modelValue: unknown;
  field: any;
  nodeId: string;
}>();

const emit = defineEmits(['update:modelValue']);

const updateValue = (val: string) => {
  if (val === '') {
    emit('update:modelValue', null);
  } else {
    emit('update:modelValue', Number(val));
  }
};
</script>
