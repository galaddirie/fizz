<script setup lang="ts">
import AddStepPicker from '@/components/flow/AddStepPicker.vue';
import EditorToolbar from '@/components/flow/EditorToolbar.vue';
import ExecutionTracePanel from '@/components/flow/ExecutionTracePanel.vue';
import NodeLibrary from '@/components/flow/NodeLibrary.vue';
import PublishModal from '@/components/flow/PublishModal.vue';
import StepConfigModal from '@/components/flow/step_config/StepConfigModal.vue';
import ContextMenu from '@/components/ui/ContextMenu.vue';
import WorkflowSceneCanvas from '@/shared/ui/workflow-scene/WorkflowSceneCanvas.vue';

import type {
  WorkflowEditorRootEmits,
  WorkflowEditorViewProps,
} from './contracts/workflowEditor';
import { useWorkflowEditorRoot } from './controllers/useWorkflowEditorRoot';
import WorkflowEditorInfoPanel from './components/WorkflowEditorInfoPanel.vue';

const props = defineProps<WorkflowEditorViewProps>();
const emit = defineEmits<WorkflowEditorRootEmits>();

const { editor, chrome, sceneModel, sceneController } = useWorkflowEditorRoot(props, action =>
  emit('action', action)
);
</script>

<template>
  <div class="bg-base-100 text-base-content flex h-screen overflow-hidden font-sans">
    <NodeLibrary
      v-if="!chrome.isNodeLibraryCollapsed.value"
      :library-items="editor.nodeLibraryItems"
      :workflow-name="chrome.workflow.value.name ?? 'Untitled Workflow'"
      :workflow-status="chrome.workflow.value.status ?? 'draft'"
      :style="{ width: `${chrome.nodeLibraryWidth.value}px` }"
      class="z-20 shrink-0 relative"
      @resize-start="chrome.handleNodeLibraryResizeStart"
      @toggle-collapse="chrome.toggleNodeLibraryCollapsed"
    />
    <div
      v-else
      class="z-20 relative flex h-full w-11 shrink-0 items-start justify-center bg-base-100/90 px-2 pt-3.5"
    >
      <button
        type="button"
        class="btn btn-ghost btn-sm h-9 w-7 p-0 text-base-content/45 hover:bg-base-200/70 hover:text-base-content/80"
        aria-label="Expand node library panel"
        title="Expand panel"
        @click="chrome.toggleNodeLibraryCollapsed"
      >
        <svg class="h-4 w-4" viewBox="0 0 20 20" fill="currentColor"><path fill-rule="evenodd" d="M7.22 4.22a.75.75 0 011.06 0l5.25 5.25a.75.75 0 010 1.06l-5.25 5.25a.75.75 0 11-1.06-1.06L11.94 10 7.22 5.28a.75.75 0 010-1.06z" clip-rule="evenodd" /></svg>
      </button>

      <div
        class="absolute inset-y-0 -right-4 w-8 cursor-col-resize touch-none"
        role="separator"
        aria-label="Resize node library panel"
        aria-orientation="vertical"
        @pointerdown.stop="chrome.handleNodeLibraryResizeStart($event, true)"
      />
    </div>

    <div class="relative flex min-w-0 flex-1 flex-col pt-3.5">
      <div
        v-if="!chrome.isNodeLibraryCollapsed.value"
        class="absolute inset-y-0 -left-4 z-40 w-12 cursor-col-resize touch-none"
        role="separator"
        aria-label="Resize node library panel"
        aria-orientation="vertical"
        @pointerdown.stop="chrome.handleNodeLibraryResizeStart"
      />

      <div class="absolute right-0 top-[14px] z-30 flex items-start">
        <EditorToolbar
          :presences="editor.presences"
          :can-undo="editor.undoStore.canUndo"
          :can-redo="editor.undoStore.canRedo"
          :undo-tooltip="editor.undoStore.undoTooltip"
          :redo-tooltip="editor.undoStore.redoTooltip"
          :is-undo-pending="editor.undoStore.isPending"
          @save="editor.handleSave"
          @undo="editor.handleUndo"
          @redo="editor.handleRedo"
          @run-test="editor.handleRunTest"
          @open-revisions="chrome.emitRevisionOpenAction"
          @publish="chrome.openPublishModal"
        />
      </div>

      <div class="relative flex flex-1 overflow-hidden rounded-tl-[20px] border-t border-l border-base-300 bg-base-200 shadow-inner">
        <WorkflowEditorInfoPanel
          :workspace-link="chrome.workspaceLink.value"
          :workspace-name="chrome.workflow.value.workspace?.name"
          :workflow-name="chrome.workflow.value.name ?? 'Untitled Workflow'"
          :presences="editor.presences"
          :last-saved="chrome.lastSaved.value"
          :last-saved-exact="chrome.lastSavedExact.value"
          :is-debug-mode="chrome.isDebugMode.value"
          :debug-status-badge="chrome.debugStatusBadge.value"
          :debug-execution-short-id="chrome.debugExecutionShortId.value"
          :debug-execution-timestamp="chrome.debugExecutionTimestamp.value"
          :debug-execution-link="chrome.debugExecutionLink.value"
          :debug-exit-link="chrome.debugExitLink.value"
          @save="chrome.emitSaveAction"
        />

        <div class="relative flex min-w-0 flex-1 flex-col">
          <div class="relative flex min-w-0 flex-1 flex-col overflow-hidden">
            <WorkflowSceneCanvas :model="sceneModel" :controller="sceneController" />

            <ExecutionTracePanel
              :execution="editor.execution"
              :step-executions="editor.stepExecutions"
              :step-name-by-id="editor.stepNameById"
              :selected-step-id="editor.store.selectedNodeId"
              :is-expanded="editor.store.isTracePanelExpanded"
              @toggle="editor.store.toggleTracePanel"
              @close="editor.store.isTracePanelExpanded = false"
              @select-step="editor.selectTraceStep"
              @run-test="editor.handleRunTest"
              @cancel="editor.handleCancelExecution"
            />
          </div>
        </div>
      </div>

      <StepConfigModal
        :is-open="editor.store.isConfigModalOpen"
        :node="editor.selectedNode"
        :step-type="editor.selectedStepType"
        :execution="editor.execution"
        :step-executions="editor.stepExecutions"
        :expression-previews="editor.expressionPreviews"
        :credential-options="props.catalog.credentialOptions"
        :editor-state="editor.editorState"
        :step-name-by-id="editor.stepNameById"
        :incoming-step-ids="editor.incomingStepIdsByStepId"
        :incoming-connections-by-target-input="editor.incomingConnectionsByTargetInputByStepId"
        :upstream-step-ids="editor.upstreamStepIdsByStepId"
        :can-edit="editor.canEdit"
        @close="editor.store.closeConfigModal"
        @save="editor.handleSaveConfig"
        @delete="editor.handleDeleteStep"
        @preview_expression="editor.handlePreviewExpression"
        @run_node="editor.handleRunNode"
        @pin_output="editor.handlePinOutput"
        @unpin_output="editor.handleUnpinOutput"
      />

      <ContextMenu
        :show="editor.store.contextMenu.show"
        :x="editor.store.contextMenu.x"
        :y="editor.store.contextMenu.y"
        :items="editor.contextMenuItems"
        @select="editor.handleContextMenuSelect"
        @close="editor.closeContextMenu"
      />

      <AddStepPicker
        :show="editor.isAddStepPickerOpen"
        :x="editor.addStepPickerX"
        :y="editor.addStepPickerY"
        :items="editor.addStepPickerItems"
        @select="editor.handleAddStepPickerSelect"
        @close="editor.closeAddStepPicker"
      />

      <PublishModal
        :is-open="chrome.isPublishModalOpen.value"
        :workflow-name="chrome.workflow.value.name ?? 'Workflow'"
        :current-version-tag="chrome.workflow.value.current_version_tag"
        :is-publishing="chrome.isPublishing.value"
        :publish-error="chrome.publishError.value"
        @close="chrome.closePublishModal"
        @publish="chrome.handlePublish"
      />
    </div>
  </div>
</template>

