<script setup lang="ts">
import { computed, onMounted, reactive, ref } from 'vue';
import { useLiveVue } from 'live_vue';
import EditorToolbar from '@/components/flow/EditorToolbar.vue';
import ExecutionTracePanel from '@/components/flow/ExecutionTracePanel.vue';
import NodeLibrary from '@/components/flow/NodeLibrary.vue';
import PublishModal from '@/components/flow/PublishModal.vue';
import StepConfigModal from '@/components/flow/StepConfigModal.vue';
import WorkflowCanvas from '@/components/flow/WorkflowCanvas.vue';
import ContextMenu from '@/components/ui/ContextMenu.vue';
import { useWorkflowEditor } from '@/composables/workflow/useWorkflowEditor';
import type { WorkflowEditorEmits, WorkflowEditorProps } from '@/types/workflowEditor';
import { BugAntIcon } from '@heroicons/vue/24/outline';

const props = withDefaults(defineProps<WorkflowEditorProps>(), {
  stepTypes: () => [],
  nodeLibraryItems: () => [],
  execution: null,
  stepExecutions: () => [],
  editorState: undefined,
  presences: () => [],
  currentUserId: undefined,
  expressionPreviews: () => ({}),
  debugExecutionId: null,
});

const emit = defineEmits<WorkflowEditorEmits>();
const editor = reactive(useWorkflowEditor(props, emit));
const live = useLiveVue();

// Publish modal state
const isPublishModalOpen = ref(false);
const isPublishing = ref(false);
const publishError = ref<string | null>(null);

function openPublishModal() {
  publishError.value = null;
  isPublishModalOpen.value = true;
}

function closePublishModal() {
  if (!isPublishing.value) {
    isPublishModalOpen.value = false;
  }
}

function handlePublish(payload: { version_tag: string; changelog: string }) {
  isPublishing.value = true;
  publishError.value = null;
  emit('publish_workflow', payload);
}

const isDebugMode = computed(() => !!props.debugExecutionId);
const debugExecutionShortId = computed(() => {
  const id = props.debugExecutionId ?? props.execution?.id ?? '';
  return id ? id.slice(0, 8) : '';
});
const debugExecutionTimestamp = computed(() => {
  const timestamp = props.execution?.started_at ?? props.execution?.inserted_at;
  if (!timestamp) return null;
  const date = new Date(timestamp);
  if (Number.isNaN(date.getTime())) return null;
  return date.toLocaleString();
});
const debugExecutionStatus = computed(() => props.execution?.status ?? 'pending');
const debugStatusConfig = {
  pending: { class: 'bg-base-200 text-base-content/70', label: 'Pending' },
  running: { class: 'bg-primary/15 text-primary', label: 'Running' },
  paused: { class: 'bg-warning/15 text-warning', label: 'Paused' },
  completed: { class: 'bg-success/15 text-success', label: 'Completed' },
  failed: { class: 'bg-error/15 text-error', label: 'Failed' },
  cancelled: { class: 'bg-base-200 text-base-content/70', label: 'Cancelled' },
  timeout: { class: 'bg-warning/15 text-warning', label: 'Timeout' },
} as const;
const debugStatusBadge = computed(() => {
  const key = debugExecutionStatus.value as keyof typeof debugStatusConfig;
  return debugStatusConfig[key] ?? debugStatusConfig.pending;
});
const debugExecutionLink = computed(() => {
  if (!props.workflow?.id || !props.debugExecutionId) return null;
  return `/workflows/${props.workflow.id}/execution/${props.debugExecutionId}`;
});
const debugExitLink = computed(() => {
  if (!props.workflow?.id) return null;
  return `/workflows/${props.workflow.id}/edit`;
});

// Listen for publish result from backend
onMounted(() => {
  live.handleEvent('publish_result', (payload: { success: boolean; error?: string }) => {
    isPublishing.value = false;
    if (payload.success) {
      isPublishModalOpen.value = false;
    } else if (payload.error) {
      publishError.value = payload.error;
    }
  });
});
</script>

<template>
  <div class="bg-base-300 text-base-content flex h-screen flex-col overflow-hidden font-sans">
    <EditorToolbar
      :workflow-name="editor.workflow?.name ?? 'Untitled Workflow'"
      :is-saving="false"
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
      @open-revisions="emit('navigate_revisions')"
      @publish="openPublishModal"
    />

    <div
      v-if="isDebugMode"
      class="border-base-200 bg-warning/5 text-base-content/80 border-b px-6 py-3 text-xs shadow-sm"
    >
      <div class="flex flex-wrap items-center justify-between gap-4">
        <div class="flex items-center gap-3">
          <div
            class="bg-warning/15 text-warning flex h-10 w-10 items-center justify-center rounded-2xl"
          >
            <BugAntIcon class="h-5 w-5" />
          </div>
          <div class="space-y-1">
            <div class="flex flex-wrap items-center gap-2">
              <span class="text-warning/80 text-[10px] font-semibold tracking-[0.3em] uppercase">
                Debug Mode
              </span>
              <span
                class="rounded-full px-2 py-0.5 text-[10px] font-semibold"
                :class="debugStatusBadge.class"
              >
                {{ debugStatusBadge.label }}
              </span>
            </div>
            <p class="text-base-content/60 text-[11px]">
              Using execution {{ debugExecutionShortId }}
              <span v-if="debugExecutionTimestamp">- {{ debugExecutionTimestamp }}</span>
              - Pin outputs on nodes to reuse this data in previews.
            </p>
          </div>
        </div>
        <div class="flex items-center gap-2">
          <a
            v-if="debugExecutionLink"
            :href="debugExecutionLink"
            class="btn btn-xs btn-ghost border-base-300 bg-base-100/80 text-base-content/70 hover:bg-base-200"
          >
            View execution
          </a>
          <a
            v-if="debugExitLink"
            :href="debugExitLink"
            class="btn btn-xs btn-primary text-primary-content shadow-primary/20 shadow-sm"
          >
            Exit debug
          </a>
        </div>
      </div>
    </div>

    <div class="relative flex flex-1 overflow-hidden">
      <NodeLibrary :library-items="editor.nodeLibraryItems" class="shrink-0" />

      <div class="relative flex min-w-0 flex-1 flex-col">
        <WorkflowCanvas
          :nodes="editor.nodes"
          :edges="editor.edges"
          :node-types="editor.nodeTypes"
          :edge-types="editor.edgeTypes"
          :can-edit="editor.canEdit"
          :is-revision-preview-active="false"
          preview-label=""
          :is-mounted="editor.isMounted"
          :other-user-presences="editor.otherUserPresences"
          :current-user-id="editor.currentUserId"
          :viewport="editor.viewport"
          :mini-map-node-color="editor.miniMapNodeColor"
          :set-canvas-ref="editor.setCanvasRef"
          :set-vue-flow-ref="editor.setVueFlowRef"
          :handle-pane-mouse-move="editor.handlePaneMouseMove"
          :handle-node-click="editor.handleNodeClick"
          :handle-node-double-click="editor.handleNodeDoubleClick"
          :handle-node-context-menu="editor.handleNodeContextMenu"
          :handle-selection-change="editor.handleSelectionChange"
          :handle-selection-context-menu="editor.handleSelectionContextMenu"
          :handle-pane-context-menu="editor.handlePaneContextMenu"
          :handle-edge-update="editor.handleEdgeUpdate"
          :handle-drag-over="editor.handleDragOver"
          :handle-drop="editor.handleDrop"
          :is-execution-failed="editor.isExecutionFailed"
          :is-execution-running="editor.isExecutionRunning"
          :on-run-test="editor.handleRunTest"
          :on-cancel-execution="editor.handleCancelExecution"
        />

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

      <StepConfigModal
        :is-open="editor.store.isConfigModalOpen"
        :node="editor.selectedNode"
        :step-type="editor.selectedStepType"
        :execution="editor.execution"
        :step-executions="editor.stepExecutions"
        :expression-previews="editor.expressionPreviews"
        :editor-state="editor.editorState"
        :step-name-by-id="editor.stepNameById"
        :incoming-step-ids="editor.incomingStepIdsByStepId"
        :upstream-step-ids="editor.upstreamStepIdsByStepId"
        :can-edit="editor.canEdit"
        @close="editor.store.closeConfigModal"
        @save="editor.handleSaveConfig"
        @delete="editor.handleDeleteStep"
        @preview_expression="editor.handlePreviewExpression"
        @run_node="editor.handleRunNode"
        @pin_output="editor.handlePinOutput"
        @unpin_output="editor.handleUnpinOutput"
        @toggle_webhook_test="editor.handleToggleWebhookTest"
      />

      <ContextMenu
        :show="editor.store.contextMenu.show"
        :x="editor.store.contextMenu.x"
        :y="editor.store.contextMenu.y"
        :items="editor.contextMenuItems"
        @select="editor.handleContextMenuSelect"
        @close="editor.closeContextMenu"
      />

      <PublishModal
        :is-open="isPublishModalOpen"
        :workflow-name="editor.workflow?.name ?? 'Workflow'"
        :current-version-tag="editor.workflow?.current_version_tag"
        :is-publishing="isPublishing"
        :publish-error="publishError"
        @close="closePublishModal"
        @publish="handlePublish"
      />
    </div>
  </div>
</template>
