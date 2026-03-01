<script setup lang="ts">
import { computed, nextTick, ref } from 'vue';
import { Position } from '@vue-flow/core';
import type { NodeProps } from '@vue-flow/core';
import Handle from './Handle.vue';
import { colorMap, type NodeStatus, oklchToHex, darkenColor, lightenColor } from '@/lib/color';
import { useThemeStore } from '@/stores/theme';
import type { StepHandleQuickAddRequest, StepNodeData, StepSubnodeSlot } from '@/types/workflow';
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
  ChatBubbleLeftRightIcon,
  ArrowsPointingOutIcon,
  ArrowsPointingInIcon,
  CheckIcon,
  ExclamationCircleIcon,
  ClockIcon,
  PlayIcon as PlayOutlineIcon,
  ForwardIcon,
  PauseIcon,
  BookmarkIcon,
  LockClosedIcon,
  EyeIcon,
  EyeSlashIcon,
  BoltIcon,
  CircleStackIcon,
  VariableIcon,
  PencilIcon,
  XCircleIcon,
} from '@heroicons/vue/24/outline';
import { PlayIcon, BookmarkIcon as BookmarkSolidIcon } from '@heroicons/vue/24/solid';

const props = defineProps<NodeProps<StepNodeData>>();
const themeStore = useThemeStore();
const canEdit = computed(() => props.data.canEdit ?? true);
const isSubnode = computed(() => props.data.node_role === 'subnode');

const isEditing = ref(false);
const nameDraft = ref(props.data.name || 'Untitled Step');
const nameInputRef = ref<HTMLInputElement | null>(null);

// Compute effective status (pinned takes precedence for display)
const effectiveStatus = computed<NodeStatus>(() => {
  if (props.data.pinned) return 'pinned';
  if (props.data.disabled) return 'skipped';
  return props.data.status ?? 'pending';
});

// Icon mapping for step types
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
  'hero-chat-bubble-left-right': ChatBubbleLeftRightIcon,
} as const;

type IconName = keyof typeof iconComponents;

const isImageIcon = (iconName?: string) =>
  !!iconName &&
  (iconName.startsWith('/') || /\.(svg|png|jpe?g|webp)$/i.test(iconName));

const IconComponent = computed(() => {
  const iconKey = props.data.icon as IconName;
  return iconComponents[iconKey] || CodeBracketIcon;
});

// Status indicator icons
const statusIconMap = {
  pending: null,
  queued: PauseIcon,
  running: ClockIcon,
  completed: CheckIcon,
  failed: ExclamationCircleIcon,
  skipped: ForwardIcon,
  cancelled: XCircleIcon,
  pinned: BookmarkIcon,
} as const;

const StatusIcon = computed(() => statusIconMap[effectiveStatus.value]);
const hasStatusStyle = computed(() => effectiveStatus.value !== 'pending');

// Color configuration per status
const statusConfig = computed(() => {
  const isDark = themeStore.theme === 'dark';
  const adjust = (color: string, amount: number) =>
    isDark ? oklchToHex(darkenColor(color, amount)) : oklchToHex(lightenColor(color, amount));

  return {
    pending: {
      bg: adjust(colorMap.pending, isDark ? 15 : 5),
      border: adjust(colorMap.pending, isDark ? 15 : 5) + 'C0',
      text: isDark
        ? oklchToHex(lightenColor(colorMap.pending, 20))
        : oklchToHex(darkenColor(colorMap.pending, 40)),
    },
    queued: {
      bg: adjust(colorMap.queued, isDark ? 15 : 5),
      border: adjust(colorMap.queued, isDark ? 15 : 5) + 'C0',
      text: isDark
        ? oklchToHex(lightenColor(colorMap.queued, 20))
        : oklchToHex(darkenColor(colorMap.queued, 40)),
    },
    running: {
      bg: adjust(colorMap.running, isDark ? 15 : 5),
      border: adjust(colorMap.running, isDark ? 15 : 5) + 'C0',
      text: isDark
        ? oklchToHex(lightenColor(colorMap.running, 25))
        : oklchToHex(darkenColor(colorMap.running, 45)),
    },
    completed: {
      bg: adjust(colorMap.completed, isDark ? 15 : 5),
      border: adjust(colorMap.completed, isDark ? 15 : 5) + 'C0',
      text: isDark
        ? oklchToHex(lightenColor(colorMap.completed, 25))
        : oklchToHex(darkenColor(colorMap.completed, 40)),
    },
    failed: {
      bg: adjust(colorMap.failed, isDark ? 10 : 5),
      border: adjust(colorMap.failed, isDark ? 10 : 5) + 'C0',
      text: isDark
        ? oklchToHex(lightenColor(colorMap.failed, 30))
        : oklchToHex(darkenColor(colorMap.failed, 30)),
    },
    skipped: {
      bg: adjust(colorMap.skipped, isDark ? 15 : 5),
      border: adjust(colorMap.skipped, isDark ? 15 : 5) + 'C0',
      text: isDark
        ? oklchToHex(lightenColor(colorMap.skipped, 20))
        : oklchToHex(darkenColor(colorMap.skipped, 35)),
    },
    pinned: {
      bg: adjust(colorMap.pinned, isDark ? 20 : 5),
      border: adjust(colorMap.pinned, isDark ? 20 : 5) + 'C0',
      text: isDark
        ? oklchToHex(lightenColor(colorMap.pinned, 30))
        : oklchToHex(darkenColor(colorMap.pinned, 45)),
    },
    cancelled: {
      bg: adjust(colorMap.cancelled, isDark ? 15 : 5),
      border: adjust(colorMap.cancelled, isDark ? 15 : 5) + 'C0',
      text: isDark
        ? oklchToHex(lightenColor(colorMap.cancelled, 20))
        : oklchToHex(darkenColor(colorMap.cancelled, 35)),
    },
  };
});

const currentStatusStyle = computed(() => statusConfig.value[effectiveStatus.value]);

const hexToRgba = (hex: string, alpha: number) => {
  const normalized = hex.replace('#', '');
  const r = parseInt(normalized.slice(0, 2), 16);
  const g = parseInt(normalized.slice(2, 4), 16);
  const b = parseInt(normalized.slice(4, 6), 16);
  return `rgba(${r}, ${g}, ${b}, ${alpha})`;
};

// Node classes
const nodeClasses = computed(() => [
  'group relative flex flex-col transition-shadow',
  isSubnode.value
    ? 'gap-2 rounded-xl border border-dashed border-base-300 bg-base-200/20 p-3 shadow-sm'
    : 'gap-3 rounded-2xl border border-base-300/50 bg-base-100 p-4 shadow-md',
  // Different styling for trigger nodes
  props.data.step_kind === 'trigger' && !isSubnode.value ? 'rounded-[50px_0.5rem_0.5rem_10px]' : '',
  props.dragging
    ? 'cursor-grabbing shadow-xl'
    : canEdit.value
      ? 'cursor-grab hover:shadow-lg'
      : 'cursor-default',
  props.data.disabled ? 'opacity-60' : '',
  props.data.locked_by ? 'ring-2 ring-warning/50' : '',
  props.data.selected_by?.length ? 'ring-2 ring-offset-2' : '',
]);

// Node style with selection ring
const nodeStyle = computed(() => {
  const isDark = themeStore.theme === 'dark';
  let shadow = isSubnode.value
    ? isDark
      ? '0 4px 10px 2px rgba(255, 255, 255, 0.03)'
      : '0 4px 10px 2px rgba(0, 0, 0, 0.06)'
    : isDark
      ? 'inset 0px 2px 3px 0px rgba(255,255,255,0.25), 0 6px 12px 4px rgba(255, 255, 255, 0.01)'
      : 'inset 0px 2px 3px 0px rgba(255,255,255,0.95), 0 6px 12px 4px rgba(0, 0, 0, 0.08)';

  if (props.selected) {
    const ringColor = isSubnode.value
      ? hexToRgba(oklchToHex(colorMap.queued), isDark ? 0.7 : 0.9)
      : isDark
        ? 'rgba(255, 255, 255, 0.55)'
        : 'rgba(0, 0, 0, 0.95)';
    shadow += `, 0 0 0 2px ${ringColor}`;
  }

  if (props.data.isGroupingCandidate) {
    const ringColor = isDark ? 'rgba(255, 255, 255, 0.9)' : 'rgba(0, 0, 0, 0.9)';
    const haloColor = isDark ? 'rgba(255, 255, 255, 0.2)' : 'rgba(0, 0, 0, 0.2)';
    shadow += `, 0 0 0 3px ${ringColor}, 0 0 0 9px ${haloColor}`;
  }

  const style: Record<string, string> = {
    boxShadow: shadow,
  };

  if (isSubnode.value) {
    const accent = oklchToHex(colorMap.queued);
    style.backgroundColor = hexToRgba(accent, isDark ? 0.08 : 0.04);

    if (!hasStatusStyle.value || !props.selected) {
      style.borderColor = hexToRgba(accent, isDark ? 0.45 : 0.35);
    }
  }

  if (hasStatusStyle.value) {
    style.borderColor = props.selected
      ? oklchToHex(colorMap[effectiveStatus.value])
      : currentStatusStyle.value.border;
  }

  if (props.data.selected_by?.length) {
    style['--tw-ring-color'] = props.data.selected_by[0].color;
  }

  return style;
});

// Format duration for display
const formatDuration = (us?: number): string => {
  if (typeof us !== 'number' || !Number.isFinite(us)) return '—';
  if (us < 1000) return `${us}µs`;
  if (us < 1_000_000) return `${(us / 1000).toFixed(1)}ms`;
  return `${(us / 1_000_000).toFixed(2)}s`;
};

// Format bytes for display
const formatBytes = (bytes?: number): string => {
  if (bytes === undefined || bytes === null || bytes === 0) return '';
  const k = 1024;
  const sizes = ['B', 'KB', 'MB', 'GB'];
  const i = Math.floor(Math.log(bytes) / Math.log(k));
  return `${(bytes / Math.pow(k, i)).toFixed(1)}${sizes[i]}`;
};

// Whether to show timing stats
const showStats = computed(() => {
  const status = props.data.status;
  return status && status !== 'pending' && props.data.stats?.duration_us !== undefined;
});

// Determine if handles should be shown
const showInputHandle = computed(
  () => props.data.hasInput !== false && props.data.step_kind !== 'trigger'
);
const showOutputHandle = computed(() => props.data.hasOutput !== false);
const subnodeInputHandles = computed<StepSubnodeSlot[]>(() => {
  const slots = props.data.subnode_slots ?? [];
  return slots.filter(slot => slot.id && slot.id !== 'main');
});

const handleOutputQuickAdd = (screenPoint: { x: number; y: number }) => {
  if (!canEdit.value) return;

  const request: StepHandleQuickAddRequest = {
    screenPoint,
    autoConnect: {
      source_step_id: props.id,
      source_output: 'main',
    },
    filter: {
      mode: 'output',
    },
  };

  props.data.onHandleQuickAdd?.(request);
};

const handleSubnodeSlotQuickAdd = (
  slot: StepSubnodeSlot,
  screenPoint: { x: number; y: number }
) => {
  if (!canEdit.value) return;

  const acceptedTypeIds = slot.accepts?.type_ids ?? [];
  const request: StepHandleQuickAddRequest = {
    screenPoint,
    autoConnect: {
      target_step_id: props.id,
      target_input: slot.id,
    },
    filter: {
      mode: 'subnode_slot',
      accepted_type_ids: acceptedTypeIds.length > 0 ? acceptedTypeIds : undefined,
    },
  };

  props.data.onHandleQuickAdd?.(request);
};

// Inline editing functions
const startEditing = () => {
  if (!canEdit.value) return;
  isEditing.value = true;
  nameDraft.value = props.data.name || 'Untitled Step';
  nextTick(() => nameInputRef.value?.focus());
};

const commitName = () => {
  if (!canEdit.value) return;
  const nextName = nameDraft.value.trim() || 'Untitled Step';
  isEditing.value = false;

  if (nextName !== (props.data.name || 'Untitled Step')) {
    props.data.onUpdate?.(props.id, { name: nextName });
  }
};

const cancelName = () => {
  isEditing.value = false;
  nameDraft.value = props.data.name || 'Untitled Step';
};

const handleTogglePin = () => {
  if (!canEdit.value) return;
  props.data.onTogglePin?.(props.id, !!props.data.pinned);
};

const handleRunNode = () => {
  if (!canEdit.value || props.data.disabled) return;
  props.data.onRunNode?.(props.id);
};

const handleToggleDisabled = () => {
  if (!canEdit.value) return;
  props.data.onToggleDisabled?.(props.id, !!props.data.disabled);
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
  <div class="relative inline-flex group">
    <!-- Run Node Icon -->
    <PlayIcon
      v-if="canEdit && !isSubnode"
      class="absolute -top-7 left-3 z-20 size-6 cursor-pointer text-base-content/70 opacity-0 transition hover:-translate-y-0.5 hover:text-base-content group-hover:opacity-70"
      :class="{
        'opacity-70': props.selected,
        'cursor-not-allowed hover:-translate-y-0 hover:text-base-content/70': data.disabled
      }"
      aria-label="Run node"
      title="Run node"
      @click.stop="handleRunNode"
      @dblclick.stop
    />

    <!-- Disable/Enable Icon -->
    <component
      v-if="canEdit && !isSubnode"
      :is="data.disabled ? EyeSlashIcon : EyeIcon"
      class="absolute -top-7 left-12 z-20 size-6 cursor-pointer opacity-0 transition hover:-translate-y-0.5 group-hover:opacity-70"
      :class="{
        'opacity-70': props.selected,
        'text-error hover:text-error': data.disabled,
        'text-base-content/70 hover:text-base-content': !data.disabled
      }"
      :aria-label="data.disabled ? 'Enable step' : 'Disable step'"
      :title="data.disabled ? 'Enable step' : 'Disable step'"
      @click.stop="handleToggleDisabled"
      @dblclick.stop
    />

    <!-- Pin Output Icon -->
    <component
      v-if="canEdit && !isSubnode"
      :is="BookmarkSolidIcon"
      class="absolute -top-7 left-21 z-20 size-6 cursor-pointer text-base-content/70 opacity-0 transition hover:-translate-y-0.5 hover:text-base-content group-hover:opacity-70"
      :class="{ 'opacity-70': props.selected }"
      :style="data.pinned ? { color: oklchToHex(colorMap.pinned) } : undefined"
      :aria-label="data.pinned ? 'Unpin output' : 'Pin output'"
      :title="data.pinned ? 'Unpin output' : 'Pin output'"
      @click.stop="handleTogglePin"
      @dblclick.stop
    />

    <!-- Input Handle (left side — main flow) -->
    <div
      v-if="showInputHandle"
      class="absolute top-1/2 left-0 z-10 -translate-x-1/2 -translate-y-1/2"
    >
      <Handle id="main" type="target" :position="Position.Left" :node-id="props.id" />
    </div>

    <!-- Subnode Slot Handles (bottom edge, flush on the edge) -->
    <template v-if="subnodeInputHandles.length > 0">
      <div
        v-for="(slot, idx) in subnodeInputHandles"
        :key="slot.id"
        class="absolute bottom-0 z-10 flex flex-col items-center"
        :style="{
          left: `${((idx + 1) / (subnodeInputHandles.length + 1)) * 100}%`,
          transform: 'translateX(-50%) translateY(calc(40% - 8px))'
        }"
      >
        <span class="pointer-events-none mb-1 whitespace-nowrap text-[9px] font-medium text-base-content/50">
          {{ slot.title || slot.id }}
        </span>
        <Handle
          :id="slot.id"
          type="target"
          :position="Position.Bottom"
          :node-id="props.id"
          :show-add-button="canEdit"
          @add-click="point => handleSubnodeSlotQuickAdd(slot, point)"
        />
      </div>
    </template>

    <!-- Node Card -->
    <div :class="nodeClasses" :style="nodeStyle">
      <div class="flex w-full items-start gap-3">
        <!-- Icon Container -->
      <div
        :class="[
          'flex shrink-0 items-center justify-center',
          isSubnode
            ? 'bg-base-100 size-9 rounded-xl border border-base-300/70'
            : 'bg-base-200 size-11 rounded-2xl shadow-inner',
        ]"
      >
        <img
          v-if="isImageIcon(data.icon)"
          :src="data.icon"
          alt=""
          :class="isSubnode ? 'size-5 object-contain' : 'size-6 object-contain'"
        />
        <component
          v-else
          :is="IconComponent"
          :class="isSubnode ? 'text-base-content/75 size-5' : 'text-base-content/80 size-6'"
        />
      </div>

      <!-- Content -->
      <div class="min-w-0 flex-1">
        <!-- Title Row -->
        <div class="mb-1 flex items-start justify-between gap-2">
          <div class="min-w-0 w-36">
            <input
              v-if="isEditing && canEdit"
              ref="nameInputRef"
              v-model="nameDraft"
              :class="[
                'input input-xs nodrag bg-base-100/90 text-base-content/80 h-6 w-full rounded-lg font-semibold',
                isSubnode ? 'text-[11px]' : 'text-xs',
              ]"
              type="text"
              @keydown="handleNameKeydown"
              @blur="commitName"
              @mousedown.stop
            />
            <h3
              v-else
              :class="[
                'text-base-content truncate leading-tight font-semibold h-6 flex items-center',
                isSubnode ? 'text-[12px]' : 'text-sm',
              ]"
              :title="canEdit ? 'Double click to rename' : ''"
              @dblclick.stop="canEdit && startEditing()"
            >
              {{ data.name || 'Untitled Step' }}
            </h3>
          </div>

          <div class="flex items-center gap-1">
            <!-- Lock indicator -->
            <div
              v-if="data.locked_by"
              class="tooltip tooltip-left"
              :data-tip="`Locked by ${data.locked_by}`"
            >
              <LockClosedIcon class="text-warning size-4" />
            </div>

            <!-- Edit button -->
            <button
              v-if="canEdit"
              class="btn btn-ghost btn-xs opacity-0 transition-opacity group-hover:opacity-100"
              aria-label="Edit step name"
              @click.stop="startEditing"
              @dblclick.stop
            >
              <PencilIcon class="text-base-content/60 size-4" />
            </button>

          </div>
        </div>

        <!-- Remote Selection Labels -->
        <div v-if="data.selected_by?.length" class="mb-2 flex flex-wrap gap-1">
          <div
            v-for="user in data.selected_by"
            :key="user.id"
            class="rounded px-1.5 py-0.5 text-[9px] font-bold text-white shadow-sm"
            :style="{ backgroundColor: user.color }"
          >
            {{ user.name }}
          </div>
        </div>

        <!-- Meta Row -->
        <div class="flex items-center justify-between gap-2">
          <div class="flex min-w-0 items-center gap-2">
            <span class="text-base-content/60 truncate font-mono text-[11px]">
              {{ data.type_id }}
            </span>
            <span
              v-if="isSubnode"
              class="rounded border border-dashed border-base-300 px-1.5 py-0.5 text-[9px] font-semibold tracking-wide uppercase text-base-content/60"
            >
              Sub-node
            </span>
          </div>
        </div>

        <!-- Stats -->
        <div
          class="text-base-content/60  my-1 flex min-h-[16px] shrink-0 items-center gap-1 font-mono text-[11px]"
        >
          <template v-if="showStats">
            <ClockIcon class="size-3.5" />
            <span>{{ formatDuration(data.stats?.duration_us) }}</span>
            <template v-if="data.stats?.bytes">
              <span class="text-base-content/40 mx-0.5">•</span>
              <span>{{ formatBytes(data.stats?.bytes) }}</span>
            </template>
          </template>
          <!-- Multi-item progress badge -->
          <template v-if="data.itemStats?.isMultiItem">
            <span v-if="showStats" class="text-base-content/40 mx-0.5">•</span>
            <span
              :class="[
                data.itemStats.failed > 0 ? 'text-error' : '',
                data.itemStats.running > 0 ? 'text-info' : '',
                data.itemStats.completed === data.itemStats.itemsTotal ? 'text-success' : '',
              ]"
            >
              {{ data.itemStats.completed + data.itemStats.failed }}/{{
                data.itemStats.itemsTotal
              }}
              items
            </span>
            <ExclamationCircleIcon v-if="data.itemStats.failed > 0" class="text-error size-3" />
          </template>
          <!-- Invisible placeholder to maintain consistent height -->
          <span v-else-if="!showStats" class="invisible">—</span>
        </div>
      </div>
      </div> <!-- Closing top section container -->

      <!-- Status Bubble -->
      <div v-if="hasStatusStyle" class="pointer-events-none absolute -top-4 -right-4">
        <div class="relative">
          <!-- Ping animation for running -->
          <span
            v-if="effectiveStatus === 'running'"
            class="absolute inset-0 animate-ping rounded-full opacity-30"
            :style="{ backgroundColor: currentStatusStyle.bg }"
          />

          <div
            class="bg-base-100 relative flex size-11 items-center justify-center rounded-full border-2 shadow-lg"
            :style="{ borderColor: currentStatusStyle.border }"
          >
            <div
              class="flex size-9 items-center justify-center rounded-full"
              :style="{ backgroundColor: currentStatusStyle.bg }"
            >
              <!-- Spinner for running -->
              <span
                v-if="effectiveStatus === 'running'"
                class="inline-block size-4 animate-spin rounded-full border-2 border-t-transparent"
                :style="{
                  borderColor: currentStatusStyle.text + 'E6',
                  borderTopColor: 'transparent',
                }"
              />
              <!-- Status icon -->
              <component
                v-else-if="StatusIcon"
                :is="StatusIcon"
                class="size-6 drop-shadow-sm"
                :style="{ color: currentStatusStyle.text }"
              />
            </div>
          </div>
        </div>
      </div>
    </div>

    <!-- Output Handle -->
    <div
      v-if="showOutputHandle"
      class="absolute top-1/2 right-0 z-10 translate-x-1/2 -translate-y-1/2"
    >
      <Handle
        id="main"
        type="source"
        :position="Position.Right"
        :node-id="props.id"
        :show-add-button="canEdit"
        @add-click="handleOutputQuickAdd"
      />
    </div>
  </div>
</template>
