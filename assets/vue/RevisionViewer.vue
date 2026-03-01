<script setup lang="ts">
import { reactive } from 'vue';
import type { Connection, Edge, GraphNode, NodeMouseEvent } from '@vue-flow/core';

import StepConfigModal from '@/components/flow/step_config/StepConfigModal.vue';
import WorkflowCanvas from '@/components/flow/WorkflowCanvas.vue';
import { useRevisionViewer } from '@/composables/workflow/useRevisionViewer';
import { GRID_SIZE } from '@/constants/layout';
import type { RevisionViewerEmits, RevisionViewerProps } from '@/types/revisionViewer';
import type { EdgeData, WorkflowNodeData } from '@/types/workflow';
import { ArrowLeftIcon } from '@heroicons/vue/24/outline';

const props = withDefaults(defineProps<RevisionViewerProps>(), {
  versions: () => [],
  undoStack: () => [],
  stepTypes: () => [],
});

const emit = defineEmits<RevisionViewerEmits>();
const viewer = reactive(useRevisionViewer(props));

const noopMouse = (_event: MouseEvent) => {};
const noopDrag = (_event: DragEvent) => {};
const noopNodeMouse = (_event: NodeMouseEvent) => {};
const noopSelectionContext = (_event: { event: MouseEvent; nodes: GraphNode<WorkflowNodeData>[] }) => {};
const noopEdgeUpdate = (_payload: { edge: Edge<EdgeData>; connection: Connection }) => {};
const noop = () => {};
</script>

<template>
  <div class="bg-base-100 text-base-content flex h-screen overflow-hidden font-sans">
    <!-- Main content area -->
    <div class="relative flex min-w-0 flex-1 flex-col pt-3.5">
      <!-- Floating actions at top-right -->
      <div class="absolute right-0 top-[34px] z-30 flex items-start">
        <div class="mr-4 flex items-center gap-1.5 rounded-xl border border-base-200/50 bg-base-100/80 px-2 py-1 shadow-sm backdrop-blur-sm">
          <button
            class="btn btn-ghost btn-xs gap-1.5 text-base-content/60 hover:text-base-content"
            @click="emit('navigate_back')"
          >
            <ArrowLeftIcon class="h-3.5 w-3.5" />
            <span class="text-xs font-medium">Editor</span>
          </button>
          <div class="h-4 w-px bg-base-300/50"></div>
          <button
            class="btn btn-primary btn-xs"
            :disabled="!viewer.canApply"
            @click="emit('apply_revision')"
          >
            Apply
          </button>
        </div>
      </div>

      <!-- Sunken Canvas Area -->
      <div class="relative flex flex-1 overflow-hidden rounded-tr-[20px] border-t border-r border-base-300 bg-base-200 shadow-inner">
        <div class="relative flex min-w-0 flex-1 flex-col">
          <WorkflowCanvas
            :nodes="viewer.nodes"
            :edges="viewer.edges"
            :node-types="viewer.nodeTypes"
            :edge-types="viewer.edgeTypes"
            :snap-enabled="false"
            :grid-size="GRID_SIZE"
            :effective-snap-to-grid="false"
            :can-edit="false"
            :is-revision-preview-active="true"
            :preview-label="viewer.revisionLabel"
            :is-mounted="viewer.isMounted"
            :other-user-presences="[]"
            :viewport="viewer.viewport"
            :mini-map-node-color="viewer.miniMapNodeColor"
            :set-canvas-ref="viewer.setCanvasRef"
            :set-vue-flow-ref="viewer.setVueFlowRef"
            :handle-pane-mouse-move="noopMouse"
            :handle-node-click="viewer.handleNodeClick"
            :handle-node-double-click="viewer.handleNodeDoubleClick"
            :handle-node-context-menu="noopNodeMouse"
            :handle-selection-change="viewer.handleSelectionChange"
            :handle-selection-context-menu="noopSelectionContext"
            :handle-pane-context-menu="noopMouse"
            :handle-edge-update="noopEdgeUpdate"
            :handle-drag-over="noopDrag"
            :handle-drop="noopDrag"
            :is-execution-failed="false"
            :is-execution-running="false"
            :on-run-test="noop"
            :on-cancel-execution="noop"
            :on-toggle-snap="noop"
          />
        </div>
      </div>

      <StepConfigModal
        :is-open="viewer.isInspectorOpen"
        :node="viewer.selectedNode"
        :step-type="viewer.selectedStepType"
        :execution="null"
        :step-executions="[]"
        :expression-previews="{}"
        :editor-state="props.editorState"
        :step-name-by-id="viewer.stepNameById"
        :incoming-step-ids="viewer.incomingStepIdsByStepId"
        :upstream-step-ids="viewer.upstreamStepIdsByStepId"
        :can-edit="false"
        @close="viewer.closeInspector"
      />
    </div>

    <!-- Right Revision Sidebar -->
    <aside class="bg-base-100 relative flex h-full w-80 shrink-0 flex-col overflow-y-hidden">
      <div class="shrink-0 border-b border-base-200 px-4 py-3.5">
        <div class="truncate text-sm font-semibold text-base-content">{{ viewer.workflowName }}</div>
        <div class="mt-1 text-[11px] font-semibold uppercase tracking-wider text-base-content/40">Revisions</div>
      </div>

      <div class="custom-scrollbar flex-1 space-y-6 overflow-y-auto p-4">
        <section class="space-y-3">
          <div class="text-[11px] font-semibold uppercase tracking-[0.2em] text-base-content/40">
            Current
          </div>
          <button
            class="flex w-full items-start justify-between gap-3 rounded-xl border px-3 py-3 text-left text-xs transition-all"
            :class="[
              viewer.isCurrentDraft
                ? 'border-primary/40 bg-primary/10 text-primary'
                : 'border-base-200 hover:border-base-300 hover:bg-base-200/60',
            ]"
            @click="emit('select_revision', { kind: 'current' })"
          >
            <div>
              <div class="text-sm font-semibold text-base-content">Current draft</div>
              <div class="text-[11px] text-base-content/50">
                Last updated {{ viewer.formatRevisionTimestamp(viewer.workflowUpdatedAt) }}
              </div>
            </div>
            <span v-if="props.workflow.current_version_tag" class="badge badge-ghost badge-xs">
              v{{ props.workflow.current_version_tag }}
            </span>
          </button>
        </section>

        <section class="space-y-3">
          <div class="text-[11px] font-semibold uppercase tracking-[0.2em] text-base-content/40">
            Edit history
          </div>
          <div
            v-if="viewer.undoStack.length === 0"
            class="rounded-xl border border-dashed border-base-300 bg-base-200/50 p-3 text-xs text-base-content/50"
          >
            No edits yet.
          </div>
          <div v-else class="space-y-2">
            <button
              v-for="entry in viewer.undoStack"
              :key="entry.id"
              class="flex w-full items-start justify-between gap-3 rounded-xl border px-3 py-2 text-left text-xs transition-all"
              :class="[
                viewer.isSelectedUndo(entry)
                  ? 'border-primary/40 bg-primary/10 text-primary'
                  : 'border-base-200 hover:border-base-300 hover:bg-base-200/60',
              ]"
              @click="emit('select_revision', { kind: 'undo', depth: entry.depth })"
            >
              <div>
                <div class="text-sm font-semibold text-base-content">
                  {{ entry.label || 'Untitled change' }}
                </div>
                <div class="text-[11px] text-base-content/50">
                  {{ viewer.formatRevisionTimestamp(entry.timestamp) }}
                </div>
              </div>
              <span class="text-[10px] uppercase tracking-wide text-base-content/40">
                Undo {{ entry.depth }}
              </span>
            </button>
          </div>
        </section>

        <section class="space-y-3">
          <div class="text-[11px] font-semibold uppercase tracking-[0.2em] text-base-content/40">
            Published versions
          </div>
          <div
            v-if="viewer.versions.length === 0"
            class="rounded-xl border border-dashed border-base-300 bg-base-200/50 p-3 text-xs text-base-content/50"
          >
            No published versions yet.
          </div>
          <div v-else class="space-y-2">
            <button
              v-for="version in viewer.versions"
              :key="version.id"
              class="flex w-full items-start justify-between gap-3 rounded-xl border px-3 py-2 text-left text-xs transition-all"
              :class="[
                viewer.isSelectedVersion(version)
                  ? 'border-primary/40 bg-primary/10 text-primary'
                  : 'border-base-200 hover:border-base-300 hover:bg-base-200/60',
              ]"
              @click="emit('select_revision', { kind: 'version', id: version.id })"
            >
              <div>
                <div class="text-sm font-semibold text-base-content">v{{ version.version_tag }}</div>
                <div class="text-[11px] text-base-content/50">
                  {{ viewer.formatRevisionTimestamp(version.published_at) }}
                </div>
              </div>
              <span
                v-if="props.workflow.current_version_tag === version.version_tag"
                class="badge badge-xs"
              >
                Current
              </span>
            </button>
          </div>
        </section>
      </div>
    </aside>
  </div>
</template>

<style scoped>
.custom-scrollbar::-webkit-scrollbar {
  width: 4px;
}

.custom-scrollbar::-webkit-scrollbar-thumb {
  background: color-mix(in oklch, var(--color-base-content) 5%, transparent);
  border-radius: 10px;
}

.custom-scrollbar:hover::-webkit-scrollbar-thumb {
  background: color-mix(in oklch, var(--color-base-content) 10%, transparent);
}
</style>
