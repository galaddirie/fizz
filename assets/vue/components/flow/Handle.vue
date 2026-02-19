<script setup lang="ts">
import { computed } from 'vue';
import { Handle, Position } from '@vue-flow/core';
import type { HandleType } from '@vue-flow/core';

interface Props {
  id?: string;
  type?: HandleType;
  position?: Position;
  connectable?: boolean;
  connectableStart?: boolean;
  connectableEnd?: boolean;
  [key: string]: unknown;
}

const props = defineProps<Props>();

const isVertical = computed(
  () => props.position === Position.Top || props.position === Position.Bottom
);
</script>

<template>
  <Handle
    v-bind="props"
    :connectable="true"
    :connectable-start="true"
    :connectable-end="true"
    :class="[
      'border-base-300! bg-primary! rounded-full! border-2 p-0',
      isVertical ? 'size-3!' : 'h-6! w-2.5!',
    ]"
    :style="{
      boxShadow: isVertical
        ? '0 1px 3px -1px color-mix(in oklab, var(--color-primary) 40%, #0000)'
        : 'inset 0px 2px 2px 0px rgba(255, 255, 255, 0.25), 0 3px 2px -2px color-mix(in oklab, var(--color-primary) calc(30%), #0000), 0 4px 3px -2px color-mix(in oklab, var(--color-primary) calc(30%), #0000)',
    }"
  />
</template>
