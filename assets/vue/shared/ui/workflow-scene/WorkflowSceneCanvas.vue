<script setup lang="ts">
import { ref } from 'vue';
import { VueFlow } from '@vue-flow/core';
import { Background } from '@vue-flow/background';
import { Controls } from '@vue-flow/controls';
import { MiniMap } from '@vue-flow/minimap';
import '@vue-flow/controls/dist/style.css';

import CollaborativeCursors from '@/components/flow/CollaborativeCursors.vue';
import ExecutionOverlay from '@/components/flow/ExecutionOverlay.vue';
import { DEFAULT_VIEWPORT } from '@/constants/layout';
import { oklchToHex } from '@/lib/color';
import { useWindowEvent } from '@/shared/browser/useWindowEvent';

import type { WorkflowSceneController, WorkflowSceneModel } from './types';

interface Props {
  model: WorkflowSceneModel;
  controller: WorkflowSceneController;
}

const props = defineProps<Props>();

const isSelectionModifierPressed = ref(false);

const syncSelectionModifierState = (event: KeyboardEvent) => {
  isSelectionModifierPressed.value = event.shiftKey || event.metaKey || event.ctrlKey;
};

const resetSelectionModifierState = () => {
  isSelectionModifierPressed.value = false;
};

useWindowEvent('keydown', syncSelectionModifierState);
useWindowEvent('keyup', syncSelectionModifierState);
useWindowEvent('blur', resetSelectionModifierState);
</script>

<template>
  <div
    :ref="controller.setCanvasRef"
    class="relative min-w-0 flex-1 overflow-hidden"
    :class="{ 'selection-modifier-active': isSelectionModifierPressed }"
    @mousemove="controller.handlePaneMouseMove?.($event)"
  >
    <VueFlow
      :ref="controller.setVueFlowRef"
      :nodes="model.nodes"
      :edges="model.edges"
      :node-types="model.nodeTypes"
      :edge-types="model.edgeTypes"
      :nodes-connectable="model.canEdit"
      :nodes-draggable="model.canEdit"
      :edges-updatable="model.canEdit"
      :multi-selection-key-code="['Shift', 'Meta', 'Control']"
      :snap-to-grid="model.effectiveSnapToGrid"
      :snap-grid="[model.gridSize, model.gridSize]"
      :apply-default="false"
      :default-viewport="DEFAULT_VIEWPORT"
      fit-view-on-init
      @node-click="controller.handleNodeClick?.($event)"
      @node-double-click="controller.handleNodeDoubleClick?.($event)"
      @node-context-menu="controller.handleNodeContextMenu?.($event)"
      @selection-change="controller.handleSelectionChange?.($event)"
      @selection-context-menu="controller.handleSelectionContextMenu?.($event)"
      @pane-context-menu="controller.handlePaneContextMenu?.($event)"
      @edge-update="controller.handleEdgeUpdate?.($event)"
      @dragover="controller.handleDragOver?.($event)"
      @drop="controller.handleDrop?.($event)"
    >
      <Background
        :pattern-color="oklchToHex('oklch(50% 0.05 260)')"
        :gap="model.gridSize"
      />
      <Controls
        position="bottom-right"
        class="workflow-controls-panel bg-base-100 p-1 rounded-lg"
        :show-interactive="model.canEdit"
      >
        <template v-if="model.canEdit" #top>
          <button
            type="button"
            class="vue-flow__controls-button"
            :class="model.snapEnabled ? '!bg-primary/12 !text-primary' : ''"
            title="Toggle snap (Cmd/Ctrl while dragging)"
            aria-label="Toggle snap to grid"
            @click="controller.onToggleSnap?.()"
          >
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="h-4! w-4!"><path d="m12 15 4 4"/><path d="M2.352 10.648a1.205 1.205 0 0 0 0 1.704l2.296 2.296a1.205 1.205 0 0 0 1.704 0l6.029-6.029a1 1 0 1 1 3 3l-6.029 6.029a1.205 1.205 0 0 0 0 1.704l2.296 2.296a1.205 1.205 0 0 0 1.704 0l6.365-6.367A1 1 0 0 0 8.716 4.282z"/><path d="m5 8 4 4"/></svg>
          </button>
        </template>
      </Controls>
      <MiniMap position="bottom-left" :node-color="model.miniMapNodeColor" />
    </VueFlow>

    <div
      v-if="model.isPreviewActive"
      class="pointer-events-none absolute left-5 top-5 z-[1100] rounded-2xl border border-primary/20 bg-primary/10 px-4 py-2 text-xs font-semibold text-primary"
    >
      <div class="text-[10px] uppercase tracking-[0.2em]">Preview mode</div>
      <div class="text-xs font-semibold">{{ model.previewLabel }}</div>
    </div>

    <div
      v-if="model.isMounted"
      class="pointer-events-none absolute inset-0 z-[1000]"
      :style="{
        transform: `translate(${model.viewport.x}px, ${model.viewport.y}px) scale(${model.viewport.zoom})`,
        transformOrigin: '0 0',
      }"
    >
      <CollaborativeCursors
        :presences="model.otherUserPresences"
        :current-user-id="model.currentUserId"
        :zoom="model.viewport.zoom"
      />
    </div>

    <ExecutionOverlay
      :is-execution-failed="model.isExecutionFailed"
      :is-execution-running="model.isExecutionRunning"
      :is-preview-active="model.isPreviewActive"
      :workflow-executions-link="model.workflowExecutionsLink"
      @run="controller.onRunTest?.()"
      @cancel="controller.onCancelExecution?.()"
    />
  </div>
</template>

<style>
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
}
</style>
