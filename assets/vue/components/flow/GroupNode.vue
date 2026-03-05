<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, ref, watch } from 'vue';
import { useVueFlow } from '@vue-flow/core';
import type { NodeProps } from '@vue-flow/core';
import type { GroupNodeData } from '@/shared/ui/workflow-scene/types';
import {
  DEFAULT_GROUP_COLOR,
  DEFAULT_GROUP_DIMENSIONS,
  DEFAULT_GROUP_NAME_FONT_SIZE,
  DEFAULT_NODE_DIMENSIONS,
  GROUP_NAME_FONT_SIZE_MAX,
  GROUP_NAME_FONT_SIZE_MIN,
} from '@/constants/layout';
import {
  GROUP_CONTENT_INSETS,
  getGroupContentRect,
} from '@/lib/workflowGeometry';
import { workflowTrace } from '@/lib/workflowTrace';
import { isStepNode } from '@/lib/workflowGuards';
import { useThemeStore } from '@/stores/theme';
import { PencilIcon } from '@heroicons/vue/24/outline';

// Simple debounce utility
function debounce<T extends (...args: any[]) => any>(
  func: T,
  delay: number
): (...args: Parameters<T>) => void {
  let timeoutId: ReturnType<typeof setTimeout> | undefined;
  return (...args: Parameters<T>) => {
    if (timeoutId) clearTimeout(timeoutId);
    timeoutId = setTimeout(() => func.apply(null, args), delay);
  };
}

const props = defineProps<NodeProps<GroupNodeData>>();
const { getNodes, updateNode, project } = useVueFlow();
const themeStore = useThemeStore();
const canEdit = computed(() => props.data.canEdit ?? true);

const DEFAULT_NAME = 'Group';
const MIN_GROUP_WIDTH = 240;
const MIN_GROUP_HEIGHT = 180;

const isEditing = ref(false);
const nameDraft = ref(props.data.name || DEFAULT_NAME);
const nameInputRef = ref<HTMLInputElement | null>(null);
const colorInputRef = ref<HTMLInputElement | null>(null);

watch(
  () => props.data.name,
  name => {
    if (!isEditing.value) {
      nameDraft.value = name || DEFAULT_NAME;
    }
  }
);

const normalizeHexColor = (color?: string) => {
  if (!color) return DEFAULT_GROUP_COLOR;
  if (/^#[0-9A-Fa-f]{6}$/.test(color)) return color;
  return DEFAULT_GROUP_COLOR;
};

const hexToRgba = (hex: string, alpha: number) => {
  const normalized = hex.replace('#', '');
  const r = parseInt(normalized.slice(0, 2), 16);
  const g = parseInt(normalized.slice(2, 4), 16);
  const b = parseInt(normalized.slice(4, 6), 16);
  return `rgba(${r}, ${g}, ${b}, ${alpha})`;
};

const accentColor = computed(() => normalizeHexColor(props.data.color));
const isGroupingTarget = computed(() => !!props.data.isGroupingTarget);
const nodeStyle = computed(() => {
  const accent = accentColor.value;
  const selectionRing = props.selected ? `, 0 0 0 2px ${hexToRgba(accent, 0.25)}` : '';
  const groupRing = isGroupingTarget.value
    ? `, 0 0 0 3px ${groupingRingColor.value}, 0 0 0 6px ${groupingHaloColor.value}`
    : '';
  return {
    borderColor: hexToRgba(
      accent,
      isGroupingTarget.value ? 0.65 : props.selected ? 0.55 : 0.35
    ),
    backgroundColor: hexToRgba(accent, isGroupingTarget.value ? 0.16 : 0.12),
    boxShadow: `inset 0 2px 8px rgba(0, 0, 0, 0.08)${selectionRing}${groupRing}`,
  };
});

const outlineStyle = computed(() => ({
  borderColor: hexToRgba(accentColor.value, 0.2),
}));

const groupingRingColor = computed(() =>
  themeStore.theme === 'dark' ? 'rgba(255, 255, 255, 0.35)' : 'rgba(0, 0, 0, 0.65)'
);
const groupingHaloColor = computed(() =>
  themeStore.theme === 'dark' ? 'rgba(255, 255, 255, 0.12)' : 'rgba(0, 0, 0, 0.12)'
);
const groupingOutlineStyle = computed(() => ({
  borderColor: groupingRingColor.value,
  boxShadow: `0 0 0 10px ${groupingHaloColor.value}`,
}));

const handleStyle = computed(() => ({
  backgroundColor: accentColor.value,
  borderColor: hexToRgba(accentColor.value, 0.7),
}));

const nodeClasses = computed(() => [
  'group relative h-full w-full rounded-3xl border bg-base-200/30 p-4 transition-all duration-200 ease-out',
  props.dragging ? 'cursor-grabbing shadow-lg' : canEdit.value ? 'cursor-grab' : 'cursor-default',
]);

type ResizeHandle = 'n' | 's' | 'e' | 'w' | 'ne' | 'nw' | 'se' | 'sw';

type ResizeState = {
  handle: ResizeHandle;
  startPointer: { x: number; y: number };
  startPosition: { x: number; y: number };
  startSize: { width: number; height: number };
  startRight: number;
  startBottom: number;
  stepPositions: Record<string, { x: number; y: number }>;
  stepSizes: Record<string, { width: number; height: number }>;
  lastStepPositions?: Record<string, { x: number; y: number }>;
  lastBounds?: { x: number; y: number; width: number; height: number };
};

const resizeState = ref<ResizeState | null>(null);
const isResizing = ref(false);

const resizeHandles: Array<{ id: ResizeHandle; className: string }> = [
  { id: 'nw', className: 'left-0 top-0 -translate-x-1/2 -translate-y-1/2 cursor-nwse-resize' },
  { id: 'n', className: 'left-1/2 top-0 -translate-x-1/2 -translate-y-1/2 cursor-ns-resize' },
  { id: 'ne', className: 'right-0 top-0 translate-x-1/2 -translate-y-1/2 cursor-nesw-resize' },
  { id: 'e', className: 'right-0 top-1/2 translate-x-1/2 -translate-y-1/2 cursor-ew-resize' },
  { id: 'se', className: 'right-0 bottom-0 translate-x-1/2 translate-y-1/2 cursor-nwse-resize' },
  { id: 's', className: 'left-1/2 bottom-0 -translate-x-1/2 translate-y-1/2 cursor-ns-resize' },
  { id: 'sw', className: 'left-0 bottom-0 -translate-x-1/2 translate-y-1/2 cursor-nesw-resize' },
  { id: 'w', className: 'left-0 top-1/2 -translate-x-1/2 -translate-y-1/2 cursor-ew-resize' },
];

const resizeHandleVisibility = computed(() => {
  if (!canEdit.value) return 'opacity-0';
  return isResizing.value || props.selected ? 'opacity-100' : 'opacity-0 group-hover:opacity-100';
});

const getStepPositions = () => {
  const positions: Record<string, { x: number; y: number }> = {};
  const stepIds = new Set(props.data.step_ids || []);
  if (stepIds.size === 0) return positions;

  getNodes.value.forEach(node => {
    if (!isStepNode(node)) return;
    if (!stepIds.has(node.id)) return;
    positions[node.id] = { x: node.position.x, y: node.position.y };
  });

  return positions;
};

const getStepSizes = (stepPositions: ResizeState['stepPositions']) => {
  const sizes: ResizeState['stepSizes'] = {};
  const stepIds = Object.keys(stepPositions);
  if (stepIds.length === 0) return sizes;

  const nodeById = new Map(getNodes.value.map(node => [node.id, node]));
  stepIds.forEach(stepId => {
    const node = nodeById.get(stepId);
    const width = node?.dimensions?.width ?? 0;
    const height = node?.dimensions?.height ?? 0;
    sizes[stepId] = {
      width: width > 0 ? width : DEFAULT_NODE_DIMENSIONS.width,
      height: height > 0 ? height : DEFAULT_NODE_DIMENSIONS.height,
    };
  });

  return sizes;
};

const updateGroupBounds = (bounds: { x: number; y: number; width: number; height: number }) => {
  updateNode(props.id, {
    position: { x: bounds.x, y: bounds.y },
    style: { width: `${bounds.width}px`, height: `${bounds.height}px` },
  });
};

const createTxnId = () =>
  `txn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 10)}`;

const applyStepPositions = (stepPositions: ResizeState['stepPositions']) => {
  Object.entries(stepPositions).forEach(([stepId, position]) => {
    updateNode(stepId, {
      position: {
        x: position.x,
        y: position.y,
      },
    });
  });
};

const getFlowPositionFromPointer = (event: PointerEvent) => {
  if (typeof document === 'undefined') return null;

  const rootElement = document.querySelector('.vue-flow') as HTMLElement | null;
  if (!rootElement || typeof project !== 'function') return null;

  const { left, top } = rootElement.getBoundingClientRect();
  return project({
    x: event.clientX - left,
    y: event.clientY - top,
  });
};

const hasStepPositionChanges = (
  nextPositions: ResizeState['stepPositions'],
  prevPositions: ResizeState['stepPositions']
) => {
  for (const [stepId, position] of Object.entries(nextPositions)) {
    const prev = prevPositions[stepId];
    if (!prev || prev.x !== position.x || prev.y !== position.y) {
      return true;
    }
  }
  return false;
};

const buildAdjustedStepPositions = (
  state: ResizeState,
  delta: { x: number; y: number },
  bounds: { width: number; height: number }
) => {
  const basePositions: ResizeState['stepPositions'] = {};
  const stepIds = Object.keys(state.stepPositions);
  if (stepIds.length === 0) return basePositions;

  stepIds.forEach(stepId => {
    const position = state.stepPositions[stepId];
    basePositions[stepId] = {
      x: position.x - delta.x,
      y: position.y - delta.y,
    };
  });

  let minX = Infinity;
  let minY = Infinity;
  let maxX = -Infinity;
  let maxY = -Infinity;

  stepIds.forEach(stepId => {
    const position = basePositions[stepId];
    const size = state.stepSizes[stepId] ?? DEFAULT_NODE_DIMENSIONS;
    minX = Math.min(minX, position.x);
    minY = Math.min(minY, position.y);
    maxX = Math.max(maxX, position.x + size.width);
    maxY = Math.max(maxY, position.y + size.height);
  });

  if (!isFinite(minX) || !isFinite(minY)) return basePositions;

  const contentRect = getGroupContentRect(bounds, GROUP_CONTENT_INSETS);
  const innerLeft = contentRect.x;
  const innerTop = contentRect.y;
  const innerRight = contentRect.x + contentRect.width;
  const innerBottom = contentRect.y + contentRect.height;
  const innerWidth = contentRect.width;
  const innerHeight = contentRect.height;

  const shouldAdjustX = bounds.width < state.startSize.width;
  const shouldAdjustY = bounds.height < state.startSize.height;

  let shiftX = 0;
  let shiftY = 0;

  if (shouldAdjustX && innerWidth > 0) {
    const stepsWidth = maxX - minX;
    if (stepsWidth <= innerWidth) {
      if (minX < innerLeft) {
        shiftX = innerLeft - minX;
      } else if (maxX > innerRight) {
        shiftX = innerRight - maxX;
      }
    } else if (state.handle.includes('e')) {
      shiftX = innerRight - maxX;
    } else if (state.handle.includes('w')) {
      shiftX = innerLeft - minX;
    } else {
      shiftX = innerLeft - minX;
    }
  }

  if (shouldAdjustY && innerHeight > 0) {
    const stepsHeight = maxY - minY;
    if (stepsHeight <= innerHeight) {
      if (minY < innerTop) {
        shiftY = innerTop - minY;
      } else if (maxY > innerBottom) {
        shiftY = innerBottom - maxY;
      }
    } else if (state.handle.includes('s')) {
      shiftY = innerBottom - maxY;
    } else if (state.handle.includes('n')) {
      shiftY = innerTop - minY;
    } else {
      shiftY = innerTop - minY;
    }
  }

  if (shiftX === 0 && shiftY === 0) return basePositions;

  const adjustedPositions: ResizeState['stepPositions'] = {};
  stepIds.forEach(stepId => {
    const position = basePositions[stepId];
    adjustedPositions[stepId] = {
      x: position.x + shiftX,
      y: position.y + shiftY,
    };
  });

  return adjustedPositions;
};

const getStepBounds = (stepPositions: ResizeState['stepPositions'], stepSizes: ResizeState['stepSizes']) => {
  const stepIds = Object.keys(stepPositions);
  if (stepIds.length === 0) return null;

  let minX = Infinity;
  let minY = Infinity;
  let maxX = -Infinity;
  let maxY = -Infinity;

  stepIds.forEach(stepId => {
    const position = stepPositions[stepId];
    const size = stepSizes[stepId] ?? DEFAULT_NODE_DIMENSIONS;
    minX = Math.min(minX, position.x);
    minY = Math.min(minY, position.y);
    maxX = Math.max(maxX, position.x + size.width);
    maxY = Math.max(maxY, position.y + size.height);
  });

  if (!isFinite(minX) || !isFinite(minY)) return null;
  return { minX, minY, maxX, maxY };
};

const handleResizeMove = (event: PointerEvent) => {
  const state = resizeState.value;
  if (!state) return;

  const dx = event.clientX - state.startPointer.x;
  const dy = event.clientY - state.startPointer.y;

  let nextWidth = state.startSize.width;
  let nextHeight = state.startSize.height;
  let nextX = state.startPosition.x;
  let nextY = state.startPosition.y;

  const hasWest = state.handle.includes('w');
  const hasEast = state.handle.includes('e');
  const hasNorth = state.handle.includes('n');
  const hasSouth = state.handle.includes('s');

  if (hasEast) {
    nextWidth = state.startSize.width + dx;
  } else if (hasWest) {
    nextWidth = state.startSize.width - dx;
  }

  if (hasSouth) {
    nextHeight = state.startSize.height + dy;
  } else if (hasNorth) {
    nextHeight = state.startSize.height - dy;
  }

  nextWidth = Math.max(nextWidth, MIN_GROUP_WIDTH);
  nextHeight = Math.max(nextHeight, MIN_GROUP_HEIGHT);

  if (hasWest) {
    nextX = state.startRight - nextWidth;
  }

  if (hasNorth) {
    nextY = state.startBottom - nextHeight;
  }

  const delta = {
    x: nextX - state.startPosition.x,
    y: nextY - state.startPosition.y,
  };

  const baseStepPositions: ResizeState['stepPositions'] = {};
  Object.entries(state.stepPositions).forEach(([stepId, position]) => {
    baseStepPositions[stepId] = {
      x: position.x - delta.x,
      y: position.y - delta.y,
    };
  });

  const stepBounds = getStepBounds(baseStepPositions, state.stepSizes);
  if (stepBounds) {
    const minWidth = Math.max(
      stepBounds.maxX - stepBounds.minX + GROUP_CONTENT_INSETS.left + GROUP_CONTENT_INSETS.right,
      MIN_GROUP_WIDTH
    );
    const minHeight = Math.max(
      stepBounds.maxY - stepBounds.minY + GROUP_CONTENT_INSETS.top + GROUP_CONTENT_INSETS.bottom,
      MIN_GROUP_HEIGHT
    );

    if (nextWidth < minWidth) {
      nextWidth = minWidth;
      if (hasWest) {
        nextX = state.startRight - nextWidth;
      } else {
        nextX = state.startPosition.x;
      }
    }

    if (nextHeight < minHeight) {
      nextHeight = minHeight;
      if (hasNorth) {
        nextY = state.startBottom - nextHeight;
      } else {
        nextY = state.startPosition.y;
      }
    }
  }

  const bounds = { x: nextX, y: nextY, width: nextWidth, height: nextHeight };
  const adjustedDelta = {
    x: nextX - state.startPosition.x,
    y: nextY - state.startPosition.y,
  };
  const nextStepPositions = buildAdjustedStepPositions(state, adjustedDelta, bounds);
  updateGroupBounds(bounds);
  applyStepPositions(nextStepPositions);
  props.data.onEmitInteraction?.(
    getFlowPositionFromPointer(event),
    Object.keys(nextStepPositions).length > 0 ? nextStepPositions : null,
    {
      [props.id]: bounds,
    }
  );

  resizeState.value = { ...state, lastBounds: bounds, lastStepPositions: nextStepPositions };
};

const stopResize = () => {
  const state = resizeState.value;
  if (!state) return;

  window.removeEventListener('pointermove', handleResizeMove);
  window.removeEventListener('pointerup', stopResize);
  window.removeEventListener('pointercancel', stopResize);

  const bounds = state.lastBounds;
  const lastStepPositions = state.lastStepPositions;
  if (bounds) {
    let stepPositionsForCommit: Record<string, { x: number; y: number }> = {};

    if (lastStepPositions && hasStepPositionChanges(lastStepPositions, state.stepPositions)) {
      stepPositionsForCommit = lastStepPositions;
    } else if (!lastStepPositions) {
      const delta = {
        x: bounds.x - state.startPosition.x,
        y: bounds.y - state.startPosition.y,
      };

      if (delta.x !== 0 || delta.y !== 0) {
        stepPositionsForCommit = {};
        Object.entries(state.stepPositions).forEach(([stepId, position]) => {
          stepPositionsForCommit[stepId] = {
            x: position.x - delta.x,
            y: position.y - delta.y,
          };
        });
      }
    }

    const groupIdByStepId = Object.keys(stepPositionsForCommit).reduce<Record<string, string>>(
      (acc, stepId) => {
        acc[stepId] = props.id;
        return acc;
      },
      {}
    );

    const commitPayload = {
      txn_id: createTxnId(),
      base_seq: props.data.collabSeq,
      groups: [
        {
          group_id: props.id,
          position: {
            x: bounds.x,
            y: bounds.y,
            width: bounds.width,
            height: bounds.height,
          },
        },
      ],
      step_positions: stepPositionsForCommit,
      group_id_by_step_id: groupIdByStepId,
    };

    workflowTrace('drop_commit_payload', {
      source: 'group_resize',
      txn_id: commitPayload.txn_id,
      base_seq: commitPayload.base_seq,
      payload: commitPayload,
    });

    if (props.data.onCommitDragLayout) {
      props.data.onCommitDragLayout(commitPayload);
    } else {
      props.data.onUpdate?.(props.id, {
        position: {
          x: bounds.x,
          y: bounds.y,
          width: bounds.width,
          height: bounds.height,
        },
      });
      if (Object.keys(stepPositionsForCommit).length > 0) {
        props.data.onMoveSteps?.(stepPositionsForCommit);
      }
    }
  }

  props.data.onEmitInteraction?.(null, null, null);

  resizeState.value = null;
  isResizing.value = false;
};

const startResize = (handle: ResizeHandle, event: PointerEvent) => {
  if (!canEdit.value) return;
  event.preventDefault();
  event.stopPropagation();

  const width = props.dimensions.width || DEFAULT_GROUP_DIMENSIONS.width;
  const height = props.dimensions.height || DEFAULT_GROUP_DIMENSIONS.height;
  const startPosition = { x: props.position.x, y: props.position.y };

  const stepPositions = getStepPositions();
  resizeState.value = {
    handle,
    startPointer: { x: event.clientX, y: event.clientY },
    startPosition,
    startSize: { width, height },
    startRight: startPosition.x + width,
    startBottom: startPosition.y + height,
    stepPositions,
    stepSizes: getStepSizes(stepPositions),
    lastBounds: { x: startPosition.x, y: startPosition.y, width, height },
  };

  isResizing.value = true;
  window.addEventListener('pointermove', handleResizeMove);
  window.addEventListener('pointerup', stopResize);
  window.addEventListener('pointercancel', stopResize);
};

onBeforeUnmount(() => {
  window.removeEventListener('pointermove', handleResizeMove);
  window.removeEventListener('pointerup', stopResize);
  window.removeEventListener('pointercancel', stopResize);
});

const startEditing = () => {
  if (!canEdit.value) return;
  isEditing.value = true;
  nameDraft.value = props.data.name || DEFAULT_NAME;
  nextTick(() => nameInputRef.value?.focus());
};

const commitName = () => {
  const nextName = nameDraft.value.trim() || DEFAULT_NAME;
  isEditing.value = false;

  if (nextName !== (props.data.name || DEFAULT_NAME)) {
    props.data.onUpdate?.(props.id, { name: nextName });
  }
};

const cancelName = () => {
  isEditing.value = false;
  nameDraft.value = props.data.name || DEFAULT_NAME;
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

const openColorPicker = () => {
  if (!canEdit.value) return;
  colorInputRef.value?.click();
};

const debouncedUpdateColor = debounce((color: string) => {
  props.data.onUpdate?.(props.id, { color });
}, 300);

const handleColorInput = (event: Event) => {
  if (!canEdit.value) return;
  const target = event.target as HTMLInputElement | null;
  if (!target?.value) return;
  debouncedUpdateColor(target.value);
};

const clampGroupNameFontSize = (value: number) =>
  Math.min(GROUP_NAME_FONT_SIZE_MAX, Math.max(GROUP_NAME_FONT_SIZE_MIN, Math.round(value)));

const groupNameFontSize = computed(() => {
  const fontSize = props.data.font_size;
  if (typeof fontSize !== 'number' || !Number.isFinite(fontSize)) {
    return DEFAULT_GROUP_NAME_FONT_SIZE;
  }

  return clampGroupNameFontSize(fontSize);
});

const setGroupNameFontSize = (nextSize: number) => {
  if (!canEdit.value) return;

  const normalizedSize = clampGroupNameFontSize(nextSize);
  if (normalizedSize === groupNameFontSize.value) return;
  props.data.onUpdate?.(props.id, { font_size: normalizedSize });
};

const adjustGroupNameFontSize = (delta: number) => {
  setGroupNameFontSize(groupNameFontSize.value + delta);
};
</script>

<template>
  <div :class="nodeClasses" :style="nodeStyle">
    <div
      class="pointer-events-none absolute -inset-1 z-10 rounded-[28px] border-2 opacity-0 transition-opacity duration-150"
      :class="isGroupingTarget ? 'opacity-100' : 'opacity-0'"
      :style="groupingOutlineStyle"
    ></div>

    <div
      class="pointer-events-none absolute inset-0 rounded-3xl border border-dashed"
      :style="outlineStyle"
    ></div>

    <div class="relative flex items-start justify-between gap-3">
      <div class="flex min-w-0 items-center gap-2.5">
        <div class="min-w-0">

          <div class="flex items-center gap-2">
            <input
              v-if="isEditing && canEdit"
              ref="nameInputRef"
              v-model="nameDraft"
              class="input input-xs nodrag bg-base-100/90 text-base-content/80 h-6 w-36 rounded-lg text-xs font-semibold"
              type="text"
              :style="{ fontSize: `${groupNameFontSize}px` }"
              @keydown="handleNameKeydown"
              @blur="commitName"
              @mousedown.stop
            />
            <h3
              v-else
              class="text-base-content truncate font-semibold"
              :style="{ fontSize: `${groupNameFontSize}px`, lineHeight: '1.2' }"
              :title="canEdit ? 'Double click to rename' : ''"
              @dblclick.stop="canEdit && startEditing()"
            >
              {{ data.name || DEFAULT_NAME }}
            </h3>
            <button
              v-if="canEdit"
              class="btn btn-ghost btn-xs nodrag text-base-content/60 hover:text-base-content"
              type="button"
              title="Rename group"
              @click.stop="startEditing"
              @mousedown.stop
            >
              <PencilIcon class="h-3.5 w-3.5" />
            </button>
          </div>
        </div>
      </div>

      <div class="flex items-center gap-2">
        <div
          v-if="canEdit"
          class="nodrag bg-base-100/90 border-base-200 text-base-content/60 flex items-center gap-1 rounded-lg border px-1 py-0.5 shadow-sm"
          @mousedown.stop
        >
          <button
            class="h-5 w-5 rounded text-[10px] font-semibold transition hover:bg-base-200 disabled:opacity-35"
            type="button"
            title="Decrease group name font size"
            :disabled="groupNameFontSize <= GROUP_NAME_FONT_SIZE_MIN"
            @click.stop="adjustGroupNameFontSize(-1)"
            @mousedown.stop
          >
            A-
          </button>
          <span class="w-7 text-center text-[10px] font-semibold">
            {{ groupNameFontSize }}
          </span>
          <button
            class="h-5 w-5 rounded text-[10px] font-semibold transition hover:bg-base-200 disabled:opacity-35"
            type="button"
            title="Increase group name font size"
            :disabled="groupNameFontSize >= GROUP_NAME_FONT_SIZE_MAX"
            @click.stop="adjustGroupNameFontSize(1)"
            @mousedown.stop
          >
            A+
          </button>
        </div>
        <button
          v-if="canEdit"
          class="nodrag h-6 w-6 rounded-full border border-base-200 bg-base-100/90 shadow-sm"
          type="button"
          title="Edit group color"
          :style="{ backgroundColor: accentColor }"
          @click.stop="openColorPicker"
          @mousedown.stop
        ></button>
        <input
          v-if="canEdit"
          ref="colorInputRef"
          class="absolute h-0 w-0 opacity-0"
          type="color"
          :value="accentColor"
          @input="handleColorInput"
          @mousedown.stop
        />
      </div>
    </div>

    <div
      class="absolute bottom-2 right-2 text-right text-[11px] font-medium transition-colors"
      :class="isGroupingTarget ? 'text-base-content/70' : 'text-base-content/40'"
    >
      {{ isGroupingTarget ? 'Release to group' : 'Drop nodes to group' }}
    </div>

    <template v-if="canEdit">
      <button
        v-for="handle in resizeHandles"
        :key="handle.id"
        class="nodrag absolute z-20 size-3.5 rounded-full border shadow-sm transition hover:scale-110"
        :class="[handle.className, resizeHandleVisibility]"
        type="button"
        :aria-label="`Resize group ${handle.id}`"
        :style="handleStyle"
        @pointerdown="startResize(handle.id, $event)"
        @mousedown.stop
      ></button>
    </template>
  </div>
</template>
