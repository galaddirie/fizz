<script setup lang="ts">
import { computed, nextTick, ref } from 'vue';
import { Position } from '@vue-flow/core';
import type { NodeProps } from '@vue-flow/core';
import Handle from './Handle.vue';
import { colorMap, type NodeStatus, oklchToHex, darkenColor, lightenColor } from '@/lib/color';
import { useThemeStore } from '@/stores/theme';
import type { StepNodeData } from '@/types/workflow';
import {
  GlobeAltIcon,
  ServerIcon,
  CodeBracketIcon,
  EnvelopeIcon,
  ArrowPathIcon,
  CodeBracketSquareIcon,
  BugAntIcon,
  CalculatorIcon,
  FunnelIcon,
  AdjustmentsHorizontalIcon,
  ArrowDownTrayIcon,
  CursorArrowRaysIcon,
  DocumentTextIcon,
  ArrowsRightLeftIcon,
  ListBulletIcon,
  ArrowsPointingOutIcon,
  ArrowsPointingInIcon,
  CheckIcon,
  ExclamationCircleIcon,
  ClockIcon,
  ForwardIcon,
  XCircleIcon,
  BoltIcon,
  CircleStackIcon,
  VariableIcon,
  PencilIcon,
} from '@heroicons/vue/24/outline';

const props = defineProps<NodeProps<StepNodeData>>();
const themeStore = useThemeStore();
const canEdit = computed(() => props.data.canEdit ?? true);

const isEditing = ref(false);
const nameDraft = ref(props.data.name || 'Untitled');
const nameInputRef = ref<HTMLInputElement | null>(null);

// Effective status
const effectiveStatus = computed<NodeStatus>(() => {
  if (props.data.pinned) return 'pinned';
  if (props.data.disabled) return 'skipped';
  return props.data.status ?? 'pending';
});

// Icon mapping
const iconComponents = {
  'hero-globe-alt': GlobeAltIcon,
  'hero-server': ServerIcon,
  'hero-code-bracket': CodeBracketIcon,
  'hero-envelope': EnvelopeIcon,
  'hero-arrow-path': ArrowPathIcon,
  'hero-code-bracket-square': CodeBracketSquareIcon,
  'hero-bug-ant': BugAntIcon,
  'hero-calculator': CalculatorIcon,
  'hero-funnel': FunnelIcon,
  'hero-adjustments-horizontal': AdjustmentsHorizontalIcon,
  'hero-arrow-down-tray': ArrowDownTrayIcon,
  'hero-cursor-arrow-rays': CursorArrowRaysIcon,
  'hero-document-text': DocumentTextIcon,
  'hero-arrows-right-left': ArrowsRightLeftIcon,
  'hero-list-bullet': ListBulletIcon,
  'hero-arrows-pointing-out': ArrowsPointingOutIcon,
  'hero-arrows-pointing-in': ArrowsPointingInIcon,
  'hero-bolt': BoltIcon,
  'hero-circle-stack': CircleStackIcon,
  'hero-variable': VariableIcon,
} as const;

type IconName = keyof typeof iconComponents;

const isImageIcon = (iconName?: string) =>
  !!iconName &&
  (iconName.startsWith('/') || /\.(svg|png|jpe?g|webp)$/i.test(iconName));

const IconComponent = computed(() => {
  const iconKey = props.data.icon as IconName;
  return iconComponents[iconKey] || CodeBracketIcon;
});

const hasStatusStyle = computed(() => effectiveStatus.value !== 'pending');
const isRunning = computed(() => effectiveStatus.value === 'running');

// Status dot color
const statusDotColor = computed(() => {
  const isDark = themeStore.theme === 'dark';
  const status = effectiveStatus.value;
  if (status === 'pending') return 'transparent';
  const color = colorMap[status];
  return isDark ? oklchToHex(lightenColor(color, 5)) : oklchToHex(color);
});

// Circle style
const circleStyle = computed(() => {
  const isDark = themeStore.theme === 'dark';
  const style: Record<string, string> = {};

  if (props.selected) {
    const ringColor = isDark ? 'rgba(255, 255, 255, 0.6)' : 'rgba(0, 0, 0, 0.85)';
    style.boxShadow = `0 0 0 2px ${ringColor}, 0 2px 8px rgba(0, 0, 0, 0.12)`;
  } else if (props.data.isGroupingCandidate) {
    const ringColor = isDark ? 'rgba(255, 255, 255, 0.9)' : 'rgba(0, 0, 0, 0.9)';
    const haloColor = isDark ? 'rgba(255, 255, 255, 0.15)' : 'rgba(0, 0, 0, 0.1)';
    style.boxShadow = `0 0 0 2px ${ringColor}, 0 0 0 6px ${haloColor}`;
  } else {
    style.boxShadow = isDark
      ? '0 1px 3px rgba(0, 0, 0, 0.4), 0 1px 2px rgba(0, 0, 0, 0.3)'
      : '0 1px 3px rgba(0, 0, 0, 0.08), 0 1px 2px rgba(0, 0, 0, 0.06)';
  }

  if (hasStatusStyle.value) {
    const statusColor = oklchToHex(colorMap[effectiveStatus.value]);
    style.borderColor = props.selected ? statusColor : statusColor + '80';
  }

  return style;
});

// Inline editing
const startEditing = () => {
  if (!canEdit.value) return;
  isEditing.value = true;
  nameDraft.value = props.data.name || 'Untitled';
  nextTick(() => nameInputRef.value?.focus());
};

const commitName = () => {
  if (!canEdit.value) return;
  const nextName = nameDraft.value.trim() || 'Untitled';
  isEditing.value = false;
  if (nextName !== (props.data.name || 'Untitled')) {
    props.data.onUpdate?.(props.id, { name: nextName });
  }
};

const cancelName = () => {
  isEditing.value = false;
  nameDraft.value = props.data.name || 'Untitled';
};

const handleNameKeydown = (event: KeyboardEvent) => {
  if (event.key === 'Enter') {
    event.preventDefault();
    commitName();
  } else if (event.key === 'Escape') {
    event.preventDefault();
    cancelName();
  }
};
</script>

<template>
  <div class="subnode-wrapper group flex flex-col items-center">
    <!-- Output Handle (top) — subnode sends data up to parent -->
    <div class="absolute -top-[3px] left-1/2 z-10 -translate-x-1/2 -translate-y-1/2">
      <Handle id="main" type="source" :position="Position.Top" />
    </div>

    <!-- Squarcle -->
    <div
      :class="[
        'relative flex size-16 items-center justify-center rounded-2xl border bg-base-100 shadow-md transition-all duration-150',
        hasStatusStyle ? '' : 'border-base-300/60 shadow-[0_4px_10px_rgba(0,0,0,0.08)]',
        props.dragging ? 'cursor-grabbing scale-105 shadow-xl' : canEdit ? 'cursor-grab hover:-translate-y-0.5 hover:shadow-lg' : 'cursor-default',
        data.disabled ? 'opacity-50' : '',
      ]"
      :style="circleStyle"
    >
      <img
        v-if="isImageIcon(data.icon)"
        :src="data.icon"
        alt=""
        class="size-7 object-contain"
      />
      <component v-else :is="IconComponent" class="text-base-content/80 size-7" />

      <!-- Status dot -->
      <div
        v-if="hasStatusStyle"
        :class="[
          'absolute -right-1 -top-1 size-3.5 rounded-full border-2 border-base-100',
          isRunning ? 'animate-pulse' : '',
        ]"
        :style="{ backgroundColor: statusDotColor }"
      />
    </div>

    <!-- Name label -->
    <div class="mt-2.5 flex max-w-28 items-center justify-center">
      <input
        v-if="isEditing && canEdit"
        ref="nameInputRef"
        v-model="nameDraft"
        class="nodrag w-full rounded-md bg-base-200 px-1.5 py-1 text-center text-xs font-semibold text-base-content/90 outline-none ring-2 ring-base-300 transition-shadow"
        type="text"
        @keydown="handleNameKeydown"
        @blur="commitName"
        @mousedown.stop
      />
      <span
        v-else
        class="text-base-content/80 max-w-28 truncate text-center text-xs font-semibold tracking-wide drop-shadow-sm transition-colors hover:text-base-content"
        :title="canEdit ? 'Double click to rename' : data.name"
        @dblclick.stop="canEdit && startEditing()"
      >
        {{ data.name || 'Untitled' }}
      </span>
    </div>
  </div>
</template>
