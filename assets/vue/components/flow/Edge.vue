<script setup lang="ts">
import { getBezierPath, useVueFlow, Position } from '@vue-flow/core';
import { computed, type CSSProperties } from 'vue';
import { lightenColor, colorMap, type NodeStatus, oklchToHex } from '@/lib/color';
import { useThemeStore } from '@/stores/theme';

interface EdgeData {
  animated?: boolean;
}

interface Props {
  id: string;
  source: string;
  target: string;
  sourceX: number;
  sourceY: number;
  targetX: number;
  targetY: number;
  sourcePosition?: Position;
  targetPosition?: Position;
  data?: EdgeData;
  markerEnd?: string;
  style?: CSSProperties;
  selected?: boolean;
  sourceHandleId?: string;
  targetHandleId?: string;
  animated?: boolean;
  label?: string;
}

const props = defineProps<Props>();
const { nodes } = useVueFlow();
const themeStore = useThemeStore();

const path = computed<string[]>(() => getBezierPath(props) as string[]);

const sourceNode = computed(() => nodes.value.find(n => n.id === props.source));
const isSelected = computed(() => props.selected || sourceNode.value?.selected);

const statusConfig = computed<Record<NodeStatus, { color: string }>>(() => ({
  pending: { color: oklchToHex(colorMap.pending) },
  queued: { color: oklchToHex(colorMap.queued) },
  running: { color: oklchToHex(colorMap.running) },
  completed: { color: oklchToHex(colorMap.completed) },
  failed: { color: oklchToHex(colorMap.failed) },
  skipped: { color: oklchToHex(colorMap.skipped) },
  pinned: { color: oklchToHex(colorMap.pinned) },
  cancelled: { color: oklchToHex(colorMap.cancelled) },
}));

const effectiveStatus = computed<NodeStatus>(() => {
  if (sourceNode.value?.data?.pinned) return 'pinned';
  if (sourceNode.value?.data?.disabled) return 'skipped';
  return sourceNode.value?.data?.status ?? 'pending';
});

const currentStatus = computed(() => statusConfig.value[effectiveStatus.value]);
const hasStatusStyle = computed(() => effectiveStatus.value !== 'pending');
const pendingColor = computed(() => {
  const neutral = themeStore.theme === 'dark' ? 'oklch(70% 0.035 240)' : 'oklch(55% 0.035 240)';

  return oklchToHex(neutral);
});

const handleColor = computed(() => {
  if (isSelected.value) {
    return themeStore.theme === 'dark' ? '#ffffff' : '#000000'; // White in dark mode, black in light mode
  }
  if (!hasStatusStyle.value) {
    return pendingColor.value;
  }
  return currentStatus.value.color;
});
const lighterColor = computed(() => lightenColor(handleColor.value, 90));

const gradientId = computed(() => `edge-gradient-${props.id}`);

// Stats from source node
const sourceStats = computed(() => sourceNode.value?.data?.stats);
const outputCount = computed(() => sourceStats.value?.out);

// Format stats for display
const statsText = computed(() => {
  const count = outputCount.value;
  if (
    count === undefined ||
    count === null ||
    count === 0 ||
    count === 'undefined' ||
    count === 'null'
  )
    return null;
  return `${count} ${count === 1 ? 'item' : 'items'}`;
});

// Calculate text position along the path (70% along the curve)
const textPosition = computed(() => {
  const t = 0.6; // Position at 60% along the line
  const x = props.sourceX + (props.targetX - props.sourceX) * t;
  const y = props.sourceY + (props.targetY - props.sourceY) * t;
  return { x, y };
});
</script>

<template>
  <g :class="['vue-flow__edge-path', { 'vue-flow__edge-animated': props.data?.animated }]">
    <defs>
      <marker
        :id="`arrow-${props.id}`"
        viewBox="0 0 10 10"
        refX="5"
        refY="5"
        markerWidth="5"
        markerHeight="5"
        orient="auto-start-reverse"
      >
        <path d="M 0 0 L 10 5 L 0 10 z" :fill="handleColor" stroke="none" />
      </marker>

      <linearGradient
        :id="gradientId"
        gradientUnits="userSpaceOnUse"
        :x1="props.sourceX"
        :y1="props.sourceY"
        :x2="props.targetX"
        :y2="props.targetY"
      >
        <stop offset="0%" :stop-color="isSelected ? lighterColor : handleColor" />
        <stop offset="100%" :stop-color="handleColor" />
      </linearGradient>
    </defs>

    <!-- soft under-stroke -->
    <path
      :d="path[0]"
      fill="none"
      :stroke="handleColor"
      stroke-opacity="0.3"
      stroke-width="5"
      stroke-linecap="round"
      class="vue-flow__edge-interaction"
    />
    <!-- main stroke -->
    <path
      :d="path[0]"
      fill="none"
      :stroke="`url(#${gradientId})`"
      stroke-width="2"
      stroke-linecap="round"
      :marker-end="`url(#arrow-${props.id})`"
      class="vue-flow__edge-interaction"
    />

    <!-- Stats text background -->
    <rect
      v-if="statsText"
      :x="textPosition.x - 20"
      :y="textPosition.y - 6"
      width="40"
      height="12"
      fill="var(--color-base-300)"
      stroke="none"
      rx="3"
    />

    <!-- Stats text -->
    <text
      v-if="statsText"
      :x="textPosition.x"
      :y="textPosition.y"
      text-anchor="middle"
      dominant-baseline="middle"
      class="vue-flow__edge-stats"
      fill="currentColor"
      font-size="10"
      font-family="ui-monospace, SFMono-Regular, monospace"
      font-weight="500"
    >
      {{ statsText }}
    </text>
  </g>
</template>

<style scoped>
.vue-flow__edge-stats {
  color: var(--color-base-content);
  stroke: var(--color-base-300);
  stroke-width: 6;
  paint-order: stroke fill;
  stroke-linejoin: round;
  stroke-linecap: round;
  user-select: none;
  -webkit-user-select: none;
  -moz-user-select: none;
  -ms-user-select: none;
}
</style>
