<script setup lang="ts">
import { computed, reactive, ref } from 'vue';
import { useLiveEvent } from 'live_vue';
import EditorToolbar from '@/components/flow/EditorToolbar.vue';
import ExecutionTracePanel from '@/components/flow/ExecutionTracePanel.vue';
import NodeLibrary from '@/components/flow/NodeLibrary.vue';
import PublishModal from '@/components/flow/PublishModal.vue';
import StepConfigModal from '@/components/flow/step_config/StepConfigModal.vue';
import WorkflowCanvas from '@/components/flow/WorkflowCanvas.vue';
import Avatar from '@/components/ui/Avatar.vue';
import ContextMenu from '@/components/ui/ContextMenu.vue';
import { useWorkflowEditor } from '@/composables/workflow/useWorkflowEditor';
import type {
  WorkflowEditorCommandType,
  WorkflowEditorEmits,
  WorkflowEditorLiveEmits,
  WorkflowEditorProps,
} from '@/types/workflowEditor';
import { BugAntIcon, SlashIcon, ArrowPathIcon } from '@heroicons/vue/24/outline';

const props = withDefaults(defineProps<WorkflowEditorProps>(), {
  stepTypes: () => [],
  nodeLibraryItems: () => [],
  execution: null,
  stepExecutions: () => [],
  editorState: undefined,
  presences: () => [],
  currentUserId: undefined,
  expressionPreviews: () => ({}),
  credentialOptions: () => [],
  debugExecutionId: null,
});

const emitToLiveView = defineEmits<WorkflowEditorLiveEmits>();

function emitCommand(type: WorkflowEditorCommandType, payload?: unknown) {
  const normalizedPayload =
    payload !== null && typeof payload === 'object'
      ? (payload as Record<string, unknown>)
      : {};

  emitToLiveView('editor_command', { type, payload: normalizedPayload });
}

const emit = ((event: WorkflowEditorCommandType, payload?: unknown) => {
  emitCommand(event, payload);
}) as WorkflowEditorEmits;

const editor = reactive(useWorkflowEditor(props, emit));

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

const lastSaved = computed(() => {
  // Use draft.updated_at (last persist) for "Last saved"; workflow.updated_at only changes on publish/rename
  const dateStr =
    editor.workflow?.draft?.updated_at ?? editor.workflow?.updated_at;
  if (!dateStr) return 'Just now';
  const date = new Date(dateStr);
  if (Number.isNaN(date.getTime())) return 'Just now';
  return date.toLocaleString(undefined, {
    month: 'short',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit',
  });
});

const statusBadge = computed(() => {
  const status = editor.workflow?.status ?? 'draft';
  const configs = {
    draft: { class: 'badge-warning', label: 'Draft' },
    active: { class: 'badge-success', label: 'Active' },
    archived: { class: 'badge-ghost', label: 'Archived' },
  };
  return configs[status as keyof typeof configs] || configs.draft;
});
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
  const workflow = editor.workflow as any;
  if (!workflow?.id || !workflow?.workspace_id || !props.debugExecutionId) return null;
  return `/workspaces/${workflow.workspace_id}/workflows/${workflow.id}/execution/${props.debugExecutionId}`;
});
const debugExitLink = computed(() => {
  const workflow = editor.workflow as any;
  if (!workflow?.id || !workflow?.workspace_id) return null;
  return `/workspaces/${workflow.workspace_id}/workflows/${workflow.id}/edit`;
});

useLiveEvent<{ success: boolean; error?: string }>(
  'workflow:publish_result',
  payload => {
    isPublishing.value = false;
    if (payload.success) {
      isPublishModalOpen.value = false;
    } else if (payload.error) {
      publishError.value = payload.error;
    }
  }
);
</script>

<template>
  <div class="bg-base-100 text-base-content flex h-screen overflow-hidden font-sans">
    <NodeLibrary
      :library-items="editor.nodeLibraryItems"
      :workflow-name="editor.workflow?.name ?? 'Untitled Workflow'"
      :workflow-status="editor.workflow?.status ?? 'draft'"
      class="z-20 shrink-0 relative"
    />

    <div class="relative flex min-w-0 flex-1 flex-col pt-3.5">
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
          @open-revisions="emit('navigate_revisions')"
          @publish="openPublishModal"
        />
      </div>

      <!-- Main Sunken Canvas Area -->
      <div class="relative flex flex-1 overflow-hidden rounded-tl-[20px] border-t border-l border-base-300 bg-base-200 shadow-inner">
        <!-- Floating Workflow Info -->
        <div class="pointer-events-none absolute left-6 top-5 z-30 flex flex-col items-start gap-1">
          <div class="pointer-events-auto rounded-xl border border-base-300/45 bg-base-100/65 px-2.5 py-1.5 shadow-sm backdrop-blur-sm">
            <div class="flex items-center gap-2">
              <a
                :href="`/workspaces/${(editor.workflow as any)?.workspace_id}`"
                class="text-base-content/65 hover:text-base-content/80 text-xs font-semibold tracking-wide transition-colors"
              >
                {{ (editor.workflow as any)?.workspace?.name || 'Workspace' }}
              </a>
              <SlashIcon class="text-base-content/35 h-3.5 w-3.5" stroke-width="2.5" />
              <span class="text-base-content/90 text-xs font-bold tracking-wide">
                {{ editor.workflow?.name ?? 'Untitled Workflow' }}
              </span>
              <div class="ml-1.5 flex items-center gap-2.5">
                <span :class="['badge badge-xs h-4 gap-1 text-[9px] font-bold opacity-75', statusBadge.class]">
                  <span class="h-1 w-1 rounded-full bg-current"></span>
                  {{ statusBadge.label }}
                </span>
                <Avatar :presences="editor.presences" class="scale-95" />
              </div>
            </div>
          </div>

          <button
            class="pointer-events-auto ml-1 inline-flex items-center gap-1 rounded-full bg-base-100/45 px-2 py-0.5 text-[9px] font-semibold tracking-tight text-base-content/50 transition-colors hover:text-base-content/70"
            @click="emit('save_workflow')"
          >
            Last saved: {{ lastSaved }}
          </button>
        </div>

        <div class="relative flex min-w-0 flex-1 flex-col">
          <div
            v-if="isDebugMode"
            class="border-base-200 bg-warning/5 text-base-content/80 relative z-10 border-b px-6 pt-5 pb-3 text-xs shadow-sm"
          >
            <div class="flex flex-wrap items-center justify-between gap-4">
              <div class="flex items-center gap-3">
                <div class="bg-warning/15 text-warning flex h-10 w-10 items-center justify-center rounded-2xl">
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

          <div class="relative flex min-w-0 flex-1 flex-col overflow-hidden">
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
        </div>
      </div>

      <StepConfigModal
        :is-open="editor.store.isConfigModalOpen"
        :node="editor.selectedNode"
        :step-type="editor.selectedStepType"
        :execution="editor.execution"
        :step-executions="editor.stepExecutions"
        :expression-previews="editor.expressionPreviews"
        :credential-options="credentialOptions"
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
