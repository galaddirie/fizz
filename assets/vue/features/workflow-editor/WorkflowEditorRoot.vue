<script setup lang="ts">
import type { StepConfigUnpinOutputPayload } from "@/components/flow/step_config/contracts";
import AddStepPicker from "@/components/flow/AddStepPicker.vue";
import CollaborativeCursors from "@/components/flow/CollaborativeCursors.vue";
import EditorToolbar from "@/components/flow/EditorToolbar.vue";
import ExecutionOverlay from "@/components/flow/ExecutionOverlay.vue";
import ExecutionTracePanel from "@/components/flow/ExecutionTracePanel.vue";
import NodeLibrary from "@/components/flow/NodeLibrary.vue";
import PublishModal from "@/components/flow/PublishModal.vue";
import StepConfigModal from "@/components/flow/step_config/StepConfigModal.vue";
import ContextMenu from "@/components/ui/ContextMenu.vue";
import WorkflowSceneCanvas from "@/shared/ui/workflow-scene/WorkflowSceneCanvas.vue";

import type {
  WorkflowEditorRootEmits,
  WorkflowEditorViewProps,
} from "./contracts/workflowEditor";
import { useWorkflowEditorRoot } from "./controllers/useWorkflowEditorRoot";
import WorkflowEditorInfoPanel from "./components/WorkflowEditorInfoPanel.vue";

const props = defineProps<WorkflowEditorViewProps>();
const emit = defineEmits<WorkflowEditorRootEmits>();

const { editor, chrome, sceneModel, sceneController } = useWorkflowEditorRoot(
  props,
  (action) => emit("action", action)
);

const handleUnpinOutput = (payload: StepConfigUnpinOutputPayload) => {
  editor.commands.inspector.unpinOutput(payload.step_id);
};
</script>

<template>
  <div
    class="bg-base-100 text-base-content flex h-screen overflow-hidden font-sans"
  >
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
        <svg class="h-4 w-4" viewBox="0 0 20 20" fill="currentColor">
          <path
            fill-rule="evenodd"
            d="M7.22 4.22a.75.75 0 011.06 0l5.25 5.25a.75.75 0 010 1.06l-5.25 5.25a.75.75 0 11-1.06-1.06L11.94 10 7.22 5.28a.75.75 0 010-1.06z"
            clip-rule="evenodd"
          />
        </svg>
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
          @save="editor.commands.document.save"
          @undo="editor.commands.document.undo"
          @redo="editor.commands.document.redo"
          @run-test="editor.commands.execution.runTest"
          @open-revisions="chrome.emitRevisionOpenAction"
          @publish="chrome.openPublishModal"
        />
      </div>

      <div
        class="relative flex flex-1 overflow-hidden rounded-tl-[20px] border-t border-l border-base-300 bg-base-200 shadow-inner"
      >
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
          @save="editor.commands.document.save"
        />

        <div class="relative flex min-w-0 flex-1 flex-col">
          <div class="relative flex min-w-0 flex-1 flex-col overflow-hidden">
            <WorkflowSceneCanvas
              :model="sceneModel"
              :controller="sceneController"
            >
              <template #overlay>
                <div
                  v-if="editor.isMounted"
                  class="pointer-events-none absolute inset-0 z-[1000]"
                  :style="{
                    transform: `translate(${editor.viewport.x}px, ${editor.viewport.y}px) scale(${editor.viewport.zoom})`,
                    transformOrigin: '0 0',
                  }"
                >
                  <CollaborativeCursors
                    :presences="editor.otherUserPresences"
                    :current-user-id="editor.currentUserId"
                    :zoom="editor.viewport.zoom"
                  />
                </div>

                <ExecutionOverlay
                  :is-execution-failed="editor.isExecutionFailed"
                  :is-execution-running="editor.isExecutionRunning"
                  :is-preview-active="false"
                  :workflow-executions-link="
                    chrome.workflowExecutionsLink.value
                  "
                  @run="editor.commands.execution.runTest"
                  @cancel="editor.commands.execution.cancel"
                />
              </template>
            </WorkflowSceneCanvas>

            <ExecutionTracePanel
              :execution="editor.execution"
              :step-executions="editor.stepExecutions"
              :step-name-by-id="editor.stepNameById"
              :selected-step-id="editor.store.selectedNodeId"
              :is-expanded="editor.store.isTracePanelExpanded"
              @toggle="editor.store.toggleTracePanel"
              @close="editor.store.isTracePanelExpanded = false"
              @select-step="editor.commands.selection.selectStep"
              @run-test="editor.commands.execution.runTest"
              @cancel="editor.commands.execution.cancel"
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
        :incoming-connections-by-target-input="
          editor.incomingConnectionsByTargetInputByStepId
        "
        :upstream-step-ids="editor.upstreamStepIdsByStepId"
        :can-edit="editor.canEdit"
        @close="editor.store.closeConfigModal"
        @save="editor.commands.inspector.saveStepConfig"
        @delete="editor.commands.inspector.deleteStep"
        @preview_expression="editor.commands.inspector.previewExpression"
        @run_node="editor.commands.step.run"
        @pin_output="editor.commands.inspector.pinOutput"
        @unpin_output="handleUnpinOutput"
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
