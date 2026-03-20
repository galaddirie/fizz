<script setup lang="ts">
import { reactive } from 'vue';
import type { Connection, Edge, GraphNode, NodeMouseEvent } from '@vue-flow/core';

import StepConfigModal from '@/components/flow/step_config/StepConfigModal.vue';
import WorkflowCanvas from '@/components/flow/WorkflowCanvas.vue';
import { useRevisionViewer } from '@/composables/workflow/useRevisionViewer';
import { GRID_SIZE } from '@/constants/layout';
import type { RevisionViewerEmits, RevisionViewerProps } from '@/types/revisionViewer';
import type { EdgeData, WorkflowNodeData } from '@/types/workflow';
import { ArrowLeftIcon, SlashIcon } from '@heroicons/vue/24/outline';

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
    <!-- Left Panel — Logo + Back to Editor -->
    <aside class="bg-base-100 relative z-20 flex h-full w-52 shrink-0 flex-col">
      <div class="shrink-0 px-4 py-3.5">
        <a :href="`/projects/${(props.workflow as any)?.project_id}`" class="group flex items-center gap-2.5">
          <div class="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-primary/10 transition-colors duration-200 group-hover:bg-primary/15">
            <svg class="h-4.5 w-4.5 text-primary" viewBox="0 0 1080 700" fill="currentColor">
              <path d="M1041.6,218.5h0c0-101.3-82.1-183.4-183.4-183.4h-332.6c-27.2,0-49.2,22-49.2,49.2v26.5c0,9.9,2,19.6,5.9,28.7l54.4,127.3c25.2,59.2,33.1,125.2-6.5,176.8l-40.9,53.3c-8.4,10.9-12.9,24.3-12.9,38v80.7c0,27.2,22,49.2,49.2,49.2h437.2c43.5,0,78.7-35.2,78.7-78.7v-6.8c0-14.2,7.9-137.2-13.2-174.9-21.1-37.7-95.8,8.6-115.4,8.6s-19.3-46.6-19.3-46.6c81.7,0,147.9-66.2,147.9-147.9ZM830.2,193.9c-1.3-41.1,32.3-74.7,73.4-73.4,37.2,1.2,67.6,31.5,68.8,68.8,1.3,41.1-32.3,74.7-73.4,73.4-37.2-1.2-67.6-31.5-68.8-68.8Z"/>
              <path d="M472.3,443.6l-40.4,52.7c-8.7,11.3-13.4,25.2-13.4,39.5v87.5c0,23-18.6,41.6-41.6,41.6H112.6c-41.8,0-75.7-33.9-75.7-75.7,0,0,99.5-554,187-554h153c23,0,35.6,47.3,43.2,72.4,67.5,225.1,130.8,262,52.2,336Z"/>
            </svg>
          </div>
          <span class="text-base-content text-lg font-bold tracking-tight transition-colors duration-200 group-hover:text-primary">Fizz</span>
        </a>
      </div>
      <div class="px-4 pt-1">
        <button
          class="flex w-full items-center gap-2 rounded-lg px-2 py-1.5 text-xs font-medium text-base-content/60 transition-colors hover:bg-base-200/80 hover:text-base-content"
          @click="emit('navigate_back')"
        >
          <ArrowLeftIcon class="h-3.5 w-3.5" />
          Back to Editor
        </button>
      </div>
    </aside>

    <!-- Main content area -->
    <div class="relative flex min-w-0 flex-1 flex-col pt-3.5">
      <!-- Floating Apply action at top-right -->
      <div class="absolute right-0 top-[14px] z-30 flex items-start">
        <div class="mr-4">
          <button
            class="btn btn-primary btn-xs rounded-xl px-4 shadow-sm"
            :disabled="!viewer.canApply"
            @click="emit('apply_revision')"
          >
            Apply
          </button>
        </div>
      </div>

      <!-- Sunken Canvas Area -->
      <div class="relative flex flex-1 overflow-hidden rounded-t-[20px] border-t border-l border-r border-base-300 bg-base-200 shadow-inner">
        <!-- Floating Workflow Info -->
        <div class="pointer-events-none absolute left-6 top-5 z-30 flex select-none flex-col items-start gap-0.5">
          <div class="px-1.5 py-0.5">
            <div class="flex items-center gap-2">
              <a
                :href="`/projects/${(props.workflow as any)?.project_id}`"
                class="pointer-events-auto select-none text-base-content/60 hover:text-base-content/80 text-xs font-medium transition-colors"
              >
                {{ (props.workflow as any)?.project?.name || 'project' }}
              </a>
              <SlashIcon class="pointer-events-none text-base-content/30 h-3.5 w-3.5" stroke-width="2.5" />
              <span class="pointer-events-none text-base-content/90 text-xs font-semibold">
                {{ viewer.workflowName }}
              </span>
            </div>
          </div>
          <div class="ml-1 px-0.5 text-[10px] font-medium text-base-content/45">
            {{ viewer.revisionLabel }}
          </div>
        </div>

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
            :is-revision-preview-active="false"
            preview-label=""
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
            <span v-if="props.draft.version" class="badge badge-ghost badge-xs">
              v{{ props.draft.version }}
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
                <div class="text-sm font-semibold text-base-content">v{{ version.version }}</div>
                <div class="text-[11px] text-base-content/50">
                  {{ viewer.formatRevisionTimestamp(version.published_at) }}
                </div>
              </div>
              <span
                v-if="props.draft.version === version.version"
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
