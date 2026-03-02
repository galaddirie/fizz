<script setup lang="ts">
import { onBeforeUnmount, onMounted, ref, type VNodeRef } from 'vue';
import type {
  Connection,
  Edge,
  EdgeTypesObject,
  GraphNode,
  Node,
  NodeMouseEvent,
  NodeTypesObject,
} from '@vue-flow/core';
import { VueFlow } from '@vue-flow/core';
import { Background } from '@vue-flow/background';
import { Controls } from '@vue-flow/controls';
import { MiniMap } from '@vue-flow/minimap';
import '@vue-flow/controls/dist/style.css';

import CollaborativeCursors from '@/components/flow/CollaborativeCursors.vue';
import ExecutionOverlay from '@/components/flow/ExecutionOverlay.vue';
import { DEFAULT_VIEWPORT } from '@/constants/layout';
import { oklchToHex } from '@/lib/color';
import type { EdgeData, UserPresence, WorkflowNodeData } from '@/types/workflow';

interface Props {
  nodes: Node<WorkflowNodeData>[];
  edges: Edge<EdgeData>[];
  nodeTypes: NodeTypesObject;
  edgeTypes: EdgeTypesObject;
  snapEnabled: boolean;
  gridSize: number;
  effectiveSnapToGrid: boolean;
  canEdit: boolean;
  isRevisionPreviewActive: boolean;
  previewLabel: string;
  isMounted: boolean;
  otherUserPresences: UserPresence[];
  currentUserId?: string;
  viewport: { x: number; y: number; zoom: number };
  miniMapNodeColor: (node: GraphNode<WorkflowNodeData>) => string;
  setCanvasRef: VNodeRef;
  setVueFlowRef: VNodeRef;
  handlePaneMouseMove: (event: MouseEvent) => void;
  handleNodeClick: (event: NodeMouseEvent) => void;
  handleNodeDoubleClick: (event: NodeMouseEvent) => void;
  handleNodeContextMenu: (event: NodeMouseEvent) => void;
  handleSelectionChange: (event: { nodes: GraphNode<WorkflowNodeData>[] }) => void;
  handleSelectionContextMenu: (event: { event: MouseEvent; nodes: GraphNode<WorkflowNodeData>[] }) => void;
  handlePaneContextMenu: (event: MouseEvent) => void;
  handleEdgeUpdate: (payload: { edge: Edge<EdgeData>; connection: Connection }) => void;
  handleDragOver: (event: DragEvent) => void;
  handleDrop: (event: DragEvent) => void;
  isExecutionFailed: boolean;
  isExecutionRunning: boolean;
  workflowExecutionsLink?: string | null;
  onRunTest: () => void;
  onCancelExecution: () => void;
  onToggleSnap: () => void;
}

defineProps<Props>();

const isSelectionModifierPressed = ref(false);

const syncSelectionModifierState = (event: KeyboardEvent) => {
  isSelectionModifierPressed.value = event.shiftKey || event.metaKey || event.ctrlKey;
};

const resetSelectionModifierState = () => {
  isSelectionModifierPressed.value = false;
};

onMounted(() => {
  window.addEventListener('keydown', syncSelectionModifierState);
  window.addEventListener('keyup', syncSelectionModifierState);
  window.addEventListener('blur', resetSelectionModifierState);
});

onBeforeUnmount(() => {
  window.removeEventListener('keydown', syncSelectionModifierState);
  window.removeEventListener('keyup', syncSelectionModifierState);
  window.removeEventListener('blur', resetSelectionModifierState);
});
</script>

<template>
  <div
    :ref="setCanvasRef"
    class="relative min-w-0 flex-1 overflow-hidden"
    :class="{ 'selection-modifier-active': isSelectionModifierPressed }"
    @mousemove="handlePaneMouseMove"
  >
    <VueFlow
      :ref="setVueFlowRef"
      :nodes="nodes"
      :edges="edges"
      :node-types="nodeTypes"
      :edge-types="edgeTypes"
      :nodes-connectable="canEdit"
      :nodes-draggable="canEdit"
      :edges-updatable="canEdit"
      :multi-selection-key-code="['Shift', 'Meta', 'Control']"
      :snap-to-grid="effectiveSnapToGrid"
      :snap-grid="[gridSize, gridSize]"
      :apply-default="false"
      :default-viewport="DEFAULT_VIEWPORT"
      fit-view-on-init
      @node-click="handleNodeClick"
      @node-double-click="handleNodeDoubleClick"
      @node-context-menu="handleNodeContextMenu"
      @selection-change="handleSelectionChange"
      @selection-context-menu="handleSelectionContextMenu"
      @pane-context-menu="handlePaneContextMenu"
      @edge-update="handleEdgeUpdate"
      @dragover="handleDragOver"
      @drop="handleDrop"
    >
      <Background
        :pattern-color="oklchToHex('oklch(50% 0.05 260)')"
        :gap="gridSize"
      />
      <Controls
        position="bottom-right"
        class="workflow-controls-panel bg-base-100 p-1 rounded-lg"
        :show-interactive="canEdit"
      >
        <template v-if="canEdit" #top>
          <button
            type="button"
            class="vue-flow__controls-button"
            :class="snapEnabled ? '!bg-primary/12 !text-primary' : ''"
            title="Toggle snap (Cmd/Ctrl while dragging)"
            aria-label="Toggle snap to grid"
            @click="onToggleSnap"
          >
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="h-4! w-4!"><path d="m12 15 4 4"/><path d="M2.352 10.648a1.205 1.205 0 0 0 0 1.704l2.296 2.296a1.205 1.205 0 0 0 1.704 0l6.029-6.029a1 1 0 1 1 3 3l-6.029 6.029a1.205 1.205 0 0 0 0 1.704l2.296 2.296a1.205 1.205 0 0 0 1.704 0l6.365-6.367A1 1 0 0 0 8.716 4.282z"/><path d="m5 8 4 4"/></svg>
          </button>
        </template>
      </Controls>
      <MiniMap position="bottom-left" :node-color="miniMapNodeColor" />
    </VueFlow>



    <div
      v-if="isRevisionPreviewActive"
      class="pointer-events-none absolute left-5 top-5 z-[1100] rounded-2xl border border-primary/20 bg-primary/10 px-4 py-2 text-xs font-semibold text-primary"
    >
      <div class="text-[10px] uppercase tracking-[0.2em]">Preview mode</div>
      <div class="text-xs font-semibold">{{ previewLabel }}</div>
    </div>

    <div
      v-if="isMounted"
      class="pointer-events-none absolute inset-0 z-[1000]"
      :style="{
        transform: `translate(${viewport.x}px, ${viewport.y}px) scale(${viewport.zoom})`,
        transformOrigin: '0 0',
      }"
    >
      <CollaborativeCursors
        :presences="otherUserPresences"
        :current-user-id="currentUserId"
        :zoom="viewport.zoom"
      />
    </div>

    <ExecutionOverlay
      :is-execution-failed="isExecutionFailed"
      :is-execution-running="isExecutionRunning"
      :is-preview-active="isRevisionPreviewActive"
      :workflow-executions-link="workflowExecutionsLink"
      @run="onRunTest"
      @cancel="onCancelExecution"
    />
  </div>
</template>

<style>
/* vue-flow library overrides — can't add Tailwind classes to library-rendered elements */
.vue-flow__panel {
  margin: 15px;
}

.workflow-controls-panel .vue-flow__controls {
  display: flex;
  align-items: center;
  gap: 2px;
  background-color: var(--color-base-100);
  border: none;
  padding: 3px;
  border-radius: 12px;
  box-shadow: none;
}

.workflow-controls-panel .vue-flow__controls-button {
  background: none;
  color: var(--color-base-content);
  border: none;
  border-radius: 8px;
  width: 30px;
  height: 30px;
  display: flex;
  align-items: center;
  justify-content: center;
  padding: 0;
  cursor: pointer;
  opacity: 0.6;
  transition: opacity 0.15s, background-color 0.15s;
}

.workflow-controls-panel .vue-flow__controls-button:hover {
  opacity: 1;
  background-color: var(--color-base-200);
}

.workflow-controls-panel .vue-flow__controls-button:disabled {
  opacity: 0.2;
  cursor: default;
}

.workflow-controls-panel .vue-flow__controls-button svg {
  width: 12px;
  height: 12px;
  max-width: none;
  max-height: none;
  fill: currentColor;
}

.vue-flow__node-group {
  z-index: 0 !important;
}

.vue-flow__node-group.vue-flow__node.selected,
.vue-flow__node-group.vue-flow__node.dragging {
  z-index: 0 !important;
}

.vue-flow__node:not(.vue-flow__node-group) {
  z-index: 10;
}

.vue-flow__edge {
  z-index: 15;
}

/* Let additive selection clicks reach nodes even when the group overlay sits above them. */
.selection-modifier-active .vue-flow__nodesselection-rect {
  pointer-events: none;
}

.vue-flow__minimap {
  border-radius: 12px;
  background-color: var(--color-base-100);
  border: 1px solid var(--color-base-300);
  box-shadow: 0 10px 15px -3px rgba(0, 0, 0, 0.1);
  z-index: 1100;
}

.vue-flow__minimap-mask {
  fill: var(--color-base-300);
  fill-opacity: 0.5;
}
</style>
