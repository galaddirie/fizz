<script setup lang="ts">
import { reactive } from 'vue';
import type { Connection, Edge, GraphNode, NodeMouseEvent } from '@vue-flow/core';

import RevisionToolbar from '@/components/flow/RevisionToolbar.vue';
import StepConfigModal from '@/components/flow/StepConfigModal.vue';
import WorkflowCanvas from '@/components/flow/WorkflowCanvas.vue';
import { useRevisionViewer } from '@/composables/workflow/useRevisionViewer';
import type { RevisionViewerEmits, RevisionViewerProps } from '@/types/revisionViewer';
import type { EdgeData, WorkflowNodeData } from '@/types/workflow';

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
  <div class="bg-base-300 text-base-content flex h-screen flex-col overflow-hidden font-sans">
    <RevisionToolbar
      :workflow-name="viewer.workflowName"
      :revision-label="viewer.revisionLabel"
      :can-apply="viewer.canApply"
      @back="emit('navigate_back')"
      @apply="emit('apply_revision')"
    />

    <div class="flex flex-1 overflow-hidden">
      <div class="relative flex min-w-0 flex-1 flex-col">
        <WorkflowCanvas
          :nodes="viewer.nodes"
          :edges="viewer.edges"
          :node-types="viewer.nodeTypes"
          :edge-types="viewer.edgeTypes"
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
        />
      </div>

      <aside
        class="bg-base-100 border-base-200 flex h-full w-80 shrink-0 flex-col border-l"
      >
        <div class="border-base-200 border-b px-4 py-4">
          <h2 class="text-sm font-semibold text-base-content">Revisions</h2>
          <p class="text-xs text-base-content/50">Browse edit history and published versions.</p>
        </div>

        <div class="flex-1 space-y-6 overflow-y-auto p-4">
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
</template>
