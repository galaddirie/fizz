<template>
  <div class="form-control w-full">
    <label v-if="showLabel && field.label" class="label">
      <span class="label-text font-medium">{{ field.label }}</span>
    </label>
    
    <input 
      type="text" 
      class="input input-bordered w-full font-mono text-sm" 
      :value="modelValue"
      @input="emit('update:modelValue', ($event.target as HTMLInputElement).value)"
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
  showLabel?: boolean;
}>();

const emit = defineEmits(['update:modelValue']);
const showLabel = computed(() => props.showLabel ?? true);
</script>
