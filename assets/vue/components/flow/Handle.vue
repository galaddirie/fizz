<script setup lang="ts">
import { computed } from 'vue';
import { Handle, Position, useNodeConnections } from '@vue-flow/core';
import type { HandleType } from '@vue-flow/core';
import { PlusIcon } from '@heroicons/vue/24/solid';

interface Props {
  id?: string;
  type?: HandleType;
  position?: Position;
  connectable?: boolean;
  connectableStart?: boolean;
  connectableEnd?: boolean;
  nodeId?: string;
  showAddButton?: boolean;
  allowWhenConnected?: boolean;
  [key: string]: unknown;
}

const props = defineProps<Props>();
const emit = defineEmits<{
  (e: 'add-click', payload: { x: number; y: number }): void;
}>();

const isVertical = computed(
  () => props.position === Position.Top || props.position === Position.Bottom
);

const nodeConnections = useNodeConnections({
  nodeId: computed(() => props.nodeId ?? undefined),
  handleType: computed(() => props.type ?? undefined),
  handleId: computed(() => props.id ?? undefined),
});

const hasConnection = computed(() => nodeConnections.value.length > 0);
const isQuickAddEnabled = computed(() => props.showAddButton === true);
const allowWhenConnected = computed(() => props.allowWhenConnected === true);

const shouldShowAddButton = computed(() => {
  if (!isQuickAddEnabled.value) return false;
  return allowWhenConnected.value || !hasConnection.value;
});

const addButtonPositionClasses = computed(() => {
  switch (props.position) {
    case Position.Right:
      return 'left-full top-1/2 ml-2 -translate-y-1/2';
    case Position.Bottom:
      return 'top-full left-1/2 mt-2 -translate-x-1/2';
    case Position.Left:
      return 'right-full top-1/2 mr-2 -translate-y-1/2';
    case Position.Top:
      return 'bottom-full left-1/2 mb-2 -translate-x-1/2';
    default:
      return 'left-full top-1/2 ml-2 -translate-y-1/2';
  }
});

const sanitizedHandleProps = computed(() => {
  const {
    nodeId: _nodeId,
    showAddButton: _showAddButton,
    allowWhenConnected: _allowWhenConnected,
    ...rest
  } = props;

  return rest;
});

const handleAddClick = (event: MouseEvent) => {
  event.preventDefault();
  event.stopPropagation();
  emit('add-click', { x: event.clientX, y: event.clientY });
};
</script>

<template>
  <div class="relative inline-flex items-center justify-center">
    <Handle
      v-bind="sanitizedHandleProps"
      :connectable="true"
      :connectable-start="true"
      :connectable-end="true"
      :class="[
        'border-base-300! bg-primary! border-2 p-0',
        isVertical ? 'w-7! h-2.5! rounded-full!' : 'h-6! w-2.5! rounded-full!',
      ]"
      :style="{
        boxShadow: isVertical
          ? 'inset 0px 2px 2px 0px rgba(255, 255, 255, 0.25), 0 3px 2px -2px color-mix(in oklab, var(--color-primary) calc(30%), #0000), 0 4px 3px -2px color-mix(in oklab, var(--color-primary) calc(30%), #0000)'
          : 'inset 0px 2px 2px 0px rgba(255, 255, 255, 0.25), 0 3px 2px -2px color-mix(in oklab, var(--color-primary) calc(30%), #0000), 0 4px 3px -2px color-mix(in oklab, var(--color-primary) calc(30%), #0000)',
      }"
    />

    <button
      v-if="shouldShowAddButton"
      type="button"
      :class="[
        'nodrag nopan absolute z-20 flex size-6 items-center justify-center rounded-full',
        'bg-primary text-primary-content',
        'shadow-sm shadow-primary/25',
        'transition-all duration-150',
        'hover:scale-110 hover:brightness-110 hover:shadow-md hover:shadow-primary/30',
        'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/50 focus-visible:ring-offset-1',
        addButtonPositionClasses,
      ]"
      title="Add and connect step"
      aria-label="Add and connect step"
      @mousedown.stop
      @dblclick.stop
      @click="handleAddClick"
    >
      <PlusIcon class="size-3.5" />
    </button>
  </div>
</template>
