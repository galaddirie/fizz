<script setup lang="ts">
import type { Connection, Edge, GraphNode, NodeMouseEvent } from '@vue-flow/core';
import { ArrowLeftIcon, SlashIcon } from '@heroicons/vue/24/outline';

import StepConfigModal from '@/components/flow/step_config/StepConfigModal.vue';
import WorkflowSceneCanvas from '@/shared/ui/workflow-scene/WorkflowSceneCanvas.vue';
import type { EdgeData, WorkflowNodeData } from '@/shared/ui/workflow-scene/types';

import type {
  RevisionViewerRootEmits,
  RevisionViewerViewProps,
} from './contracts/revisionViewer';
import RevisionHistorySidebar from './components/RevisionHistorySidebar.vue';
import { useRevisionViewerRoot } from './controllers/useRevisionViewerRoot';

const props = defineProps<RevisionViewerViewProps>();
const emit = defineEmits<RevisionViewerRootEmits>();

const root = useRevisionViewerRoot(props, action => emit('action', action));

const noopMouse = (_event: MouseEvent) => {};
const noopDrag = (_event: DragEvent) => {};
const noopNodeMouse = (_event: NodeMouseEvent) => {};
const noopSelectionContext = (_event: { event: MouseEvent; nodes: GraphNode<WorkflowNodeData>[] }) => {};
const noopEdgeUpdate = (_payload: { edge: Edge<EdgeData>; connection: Connection }) => {};
const noop = () => {};
</script>

<template>
  <div class="bg-base-100 text-base-content flex h-screen overflow-hidden font-sans">
    <aside class="bg-base-100 relative z-20 flex h-full w-52 shrink-0 flex-col">
      <div class="shrink-0 px-4 py-3.5">
        <a :href="root.workspaceLink || '#'" class="group flex items-center gap-2.5">
          <div class="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-primary/10 transition-colors duration-200 group-hover:bg-primary/15">
            <svg class="h-4.5 w-4.5 text-primary" viewBox="0 0 1080 700" fill="currentColor">
              <path d="M1041.6,218.5h0c0-101.3-82.1-183.4-183.4-183.4h-332.6c-27.2,0-49.2,22-49.2,49.2v26.5c0,9.9,2,19.6,5.9,28.7l54.4,127.3c25.2,59.2,33.1,125.2-6.5,176.8l-40.9,53.3c-8.4,10.9-12.9,24.3-12.9,38v80.7c0,27.2,22,49.2,49.2,49.2h437.2c43.5,0,78.7-35.2,78.7-78.7v-6.8c0-14.2,7.9-137.2-13.2-174.9-21.1-37.7-95.8,8.6-115.4,8.6s-19.3-46.6-19.3-46.6c81.7,0,147.9-66.2,147.9-147.9ZM830.2,193.9c-1.3-41.1,32.3-74.7,73.4-73.4,37.2,1.2,67.6,31.5,68.8,68.8,1.3,41.1-32.3,74.7-73.4,73.4-37.2-1.2-67.6-31.5-68.8-68.8Z"/><path d="M472.3,443.6l-40.4,52.7c-8.7,11.3-13.4,25.2-13.4,39.5v87.5c0,23-18.6,41.6-41.6,41.6H112.6c-41.8,0-75.7-33.9-75.7-75.7,0,0,99.5-554,187-554h153c23,0,35.6,47.3,43.2,72.4,67.5,225.1,130.8,262,52.2,336Z"/>
            </svg>
          </div>
          <span class="text-base-content text-lg font-bold tracking-tight transition-colors duration-200 group-hover:text-primary">Fizz</span>
        </a>
      </div>
      <div class="px-4 pt-1">
        <button
          id="revision-back-button"
          class="flex w-full items-center gap-2 rounded-lg px-2 py-1.5 text-xs font-medium text-base-content/60 transition-colors hover:bg-base-200/80 hover:text-base-content"
          @click="root.emitBack"
        >
          <ArrowLeftIcon class="h-3.5 w-3.5" />
          Back to Editor
        </button>
      </div>
    </aside>

    <div class="relative flex min-w-0 flex-1 flex-col pt-3.5">
      <div class="absolute right-0 top-[14px] z-30 flex items-start">
        <div class="mr-4">
          <button
            id="revision-apply-button"
            class="btn btn-primary btn-xs rounded-xl px-4 shadow-sm"
            :disabled="!root.viewer.canApply"
            @click="root.emitApply"
          >
            Apply
          </button>
        </div>
      </div>

      <div class="relative flex flex-1 overflow-hidden rounded-t-[20px] border-t border-l border-r border-base-300 bg-base-200 shadow-inner">
        <div class="pointer-events-none absolute left-6 top-5 z-30 flex select-none flex-col items-start gap-0.5">
          <div class="px-1.5 py-0.5">
            <div class="flex items-center gap-2">
              <a
                v-if="root.workspaceLink"
                :href="root.workspaceLink"
                class="pointer-events-auto select-none text-base-content/60 hover:text-base-content/80 text-xs font-medium transition-colors"
              >
                {{ props.document.workflow.workspace?.name || 'Workspace' }}
              </a>
              <span
                v-else
                class="pointer-events-none text-base-content/60 text-xs font-medium"
              >
                {{ props.document.workflow.workspace?.name || 'Workspace' }}
              </span>
              <SlashIcon class="pointer-events-none text-base-content/30 h-3.5 w-3.5" stroke-width="2.5" />
              <span class="pointer-events-none text-base-content/90 text-xs font-semibold">
                {{ root.viewer.workflowName }}
              </span>
            </div>
          </div>
          <div class="ml-1 px-0.5 text-[10px] font-medium text-base-content/45">
            {{ root.viewer.revisionLabel }}
          </div>
        </div>

        <div class="relative flex min-w-0 flex-1 flex-col">
          <WorkflowSceneCanvas :model="root.sceneModel" :controller="root.sceneController" />
        </div>
      </div>

      <StepConfigModal
        :is-open="root.viewer.isInspectorOpen"
        :node="root.viewer.selectedNode"
        :step-type="root.viewer.selectedStepType"
        :execution="null"
        :step-executions="[]"
        :expression-previews="{}"
        :editor-state="props.document.editorState"
        :step-name-by-id="root.viewer.stepNameById"
        :incoming-step-ids="root.viewer.incomingStepIdsByStepId"
        :upstream-step-ids="root.viewer.upstreamStepIdsByStepId"
        :can-edit="false"
        @close="root.viewer.closeInspector"
      />
    </div>

    <RevisionHistorySidebar
      :workflow-name="root.viewer.workflowName"
      :workflow-updated-at="root.viewer.workflowUpdatedAt"
      :current-version-tag="props.document.workflow.current_version_tag"
      :is-current-draft="root.viewer.isCurrentDraft"
      :undo-stack="root.viewer.undoStack"
      :versions="root.viewer.versions"
      :format-revision-timestamp="root.viewer.formatRevisionTimestamp"
      :is-selected-undo="root.viewer.isSelectedUndo"
      :is-selected-version="root.viewer.isSelectedVersion"
      @select-current="root.emitSelectCurrent"
      @select-undo="root.emitSelectUndo"
      @select-version="root.emitSelectVersion"
    />
  </div>
</template>
