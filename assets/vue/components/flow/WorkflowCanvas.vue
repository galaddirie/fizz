<script setup lang="ts">
import type { VNodeRef } from 'vue';
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
  onRunTest: () => void;
  onCancelExecution: () => void;
  onToggleSnap: () => void;
}

defineProps<Props>();
</script>

<template>
  <div :ref="setCanvasRef" class="relative min-w-0 flex-1 overflow-hidden" @mousemove="handlePaneMouseMove">
    <VueFlow
      :ref="setVueFlowRef"
      :nodes="nodes"
      :edges="edges"
      :node-types="nodeTypes"
      :edge-types="edgeTypes"
      :nodes-connectable="canEdit"
      :nodes-draggable="canEdit"
      :edges-updatable="canEdit"
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
      <Controls position="bottom-right" />
      <MiniMap position="bottom-left" :node-color="miniMapNodeColor" />
    </VueFlow>

    <button
      v-if="canEdit"
      type="button"
      class="absolute bottom-[15px] right-[130px] z-[1100] flex h-7 w-7 items-center justify-center rounded-md border border-white bg-white text-slate-700 shadow-sm transition-all duration-150 hover:scale-105 hover:shadow-md"
      :class="snapEnabled ? 'ring-2 ring-primary/60 text-primary' : ''"
      title="Toggle snap (Cmd/Ctrl while dragging)"
      @click="onToggleSnap"
    >
      <svg
        class="h-4 w-4"
        viewBox="0 0 24 24"
        fill="none"
        xmlns="http://www.w3.org/2000/svg"
      >
        <path
          d="m12 15 4 4"
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
          stroke="currentColor"
        />
        <path
          d="M2.352 10.648a1.205 1.205 0 0 0 0 1.704l2.296 2.296a1.205 1.205 0 0 0 1.704 0l6.029-6.029a1 1 0 1 1 3 3l-6.029 6.029a1.205 1.205 0 0 0 0 1.704l2.296 2.296a1.205 1.205 0 0 0 1.704 0l6.365-6.367A1 1 0 0 0 8.716 4.282z"
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
          stroke="currentColor"
        />
        <path
          d="m5 8 4 4"
          stroke-width="2"
          stroke-linecap="round"
          stroke-linejoin="round"
          stroke="currentColor"
        />
      </svg>
    </button>

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
      @run="onRunTest"
      @cancel="onCancelExecution"
    />
  </div>
</template>

<style>
.vue-flow__panel {
  margin: 15px;
}

.vue-flow__controls {
  display: flex;
  flex-direction: row !important;
  gap: 2px;
  background-color: var(--color-base-100);
  border: 1px solid var(--color-base-300);
  padding: 3px;
  border-radius: 10px;
  box-shadow: 0 4px 6px -1px rgba(0, 0, 0, 0.1);
}

.vue-flow__controls-button {
  background-color: var(--color-base-200);
  color: var(--color-base-content);
  border: none !important;
  border-radius: 6px !important;
  width: 20px !important;
  height: 20px !important;
  display: flex;
  align-items: center;
  justify-content: center;
  transition: all 0.15s ease-in-out;
  cursor: pointer;
}

.vue-flow__controls-button:hover {
  background-color: var(--color-base-300);
  transform: scale(1.05);
}

.vue-flow__controls-button svg {
  width: 12px !important;
  height: 12px !important;
  stroke-width: 2.5 !important;
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
