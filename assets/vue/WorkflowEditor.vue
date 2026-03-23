<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, reactive, ref } from 'vue';
import { useLiveEvent, useLiveVue } from 'live_vue';
import EditorToolbar from '@/components/flow/EditorToolbar.vue';
import ExecutionTracePanel from '@/components/flow/ExecutionTracePanel.vue';
import AddStepPicker from '@/components/flow/AddStepPicker.vue';
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
  WorkflowEditorProps,
} from '@/types/workflowEditor';
import type { TriggerImpact, WorkflowValidationError } from '@/types/workflow';
import {
  BugAntIcon,
  SlashIcon,
  ChevronDoubleRightIcon,
  ExclamationCircleIcon,
} from '@heroicons/vue/24/outline';

const props = withDefaults(defineProps<WorkflowEditorProps>(), {
  stepTypes: () => [],
  nodeLibraryItems: () => [],
  execution: null,
  stepExecutions: () => [],
  editorState: undefined,
  presences: () => [],
  currentUserId: undefined,
  collabSeq: 0,
  saveStatus: 'saved',
  saveError: null,
  expressionPreviews: () => ({}),
  credentialOptions: () => [],
  debugExecutionId: null,
  validationErrors: () => ({}),
});

const live = useLiveVue();
const compilationErrors = ref<WorkflowValidationError[]>([]);
const publishStateResetCommands = new Set<WorkflowEditorCommandType>([
  'add_step',
  'add_group',
  'update_group',
  'remove_group',
  'set_group_membership',
  'commit_drag_layout',
  'duplicate_steps',
  'update_step',
  'remove_step',
  'move_step',
  'move_steps',
  'add_connection',
  'remove_connection',
  'undo',
  'redo',
  'tidy_layout',
  'save_workflow',
]);

function emitCommand(type: WorkflowEditorCommandType, payload?: unknown) {
  if (publishStateResetCommands.has(type)) {
    publishError.value = null;
    publishValidationErrors.value = [];
    publishTriggerImpact.value = null;
    publishExecutionHashChanged.value = null;
    isValidatingPublish.value = false;
    compilationErrors.value = [];
  }

  if (type === 'run_test' || type === 'run_node') {
    compilationErrors.value = [];
  }

  const normalizedPayload =
    payload !== null && typeof payload === 'object'
      ? (payload as Record<string, unknown>)
      : {};

  live.pushEvent('editor_command', { type, payload: normalizedPayload });
}

const emit = ((event: WorkflowEditorCommandType, payload?: unknown) => {
  emitCommand(event, payload);
}) as WorkflowEditorEmits;

const editor = reactive(useWorkflowEditor(props, emit));

const NODE_LIBRARY_DEFAULT_WIDTH = 288;
const NODE_LIBRARY_MIN_WIDTH = 240;
const NODE_LIBRARY_MAX_WIDTH = 460;
const CANVAS_MIN_WIDTH = 640;
const NODE_LIBRARY_COLLAPSE_THRESHOLD = 20;
const NODE_LIBRARY_WIDTH_STORAGE_KEY = 'fizz.workflow_editor.node_library_width';
const NODE_LIBRARY_COLLAPSED_STORAGE_KEY = 'fizz.workflow_editor.node_library_collapsed';

const nodeLibraryWidth = ref(NODE_LIBRARY_DEFAULT_WIDTH);
const isResizingNodeLibrary = ref(false);
const isNodeLibraryCollapsed = ref(false);
const resizeOrigin = ref<{
  x: number;
  width: number;
  startedCollapsed: boolean;
} | null>(null);

const clampNodeLibraryWidth = (rawWidth: number) => {
  const viewportLimit =
    typeof window === 'undefined'
      ? NODE_LIBRARY_MAX_WIDTH
      : Math.max(
          NODE_LIBRARY_MIN_WIDTH,
          Math.min(NODE_LIBRARY_MAX_WIDTH, Math.floor(window.innerWidth - CANVAS_MIN_WIDTH))
        );

  return Math.min(viewportLimit, Math.max(NODE_LIBRARY_MIN_WIDTH, rawWidth));
};

const saveNodeLibraryWidth = (width: number) => {
  if (typeof window === 'undefined') return;
  window.localStorage.setItem(
    NODE_LIBRARY_WIDTH_STORAGE_KEY,
    String(clampNodeLibraryWidth(width))
  );
};

const saveNodeLibraryCollapsed = (collapsed: boolean) => {
  if (typeof window === 'undefined') return;
  window.localStorage.setItem(
    NODE_LIBRARY_COLLAPSED_STORAGE_KEY,
    collapsed ? '1' : '0'
  );
};

const setNodeLibraryCollapsed = (collapsed: boolean) => {
  isNodeLibraryCollapsed.value = collapsed;
  saveNodeLibraryCollapsed(collapsed);
};

const toggleNodeLibraryCollapsed = () => {
  setNodeLibraryCollapsed(!isNodeLibraryCollapsed.value);
};

const stopNodeLibraryResize = () => {
  const wasResizing = isResizingNodeLibrary.value;

  isResizingNodeLibrary.value = false;
  resizeOrigin.value = null;

  if (typeof window !== 'undefined') {
    window.removeEventListener('pointermove', handleNodeLibraryResizeMove);
    window.removeEventListener('pointerup', stopNodeLibraryResize);
    window.removeEventListener('pointercancel', stopNodeLibraryResize);
  }

  if (typeof document !== 'undefined') {
    document.body.classList.remove('cursor-col-resize', 'select-none');
  }

  if (wasResizing) {
    saveNodeLibraryWidth(nodeLibraryWidth.value);
    saveNodeLibraryCollapsed(isNodeLibraryCollapsed.value);
  }
};

const handleNodeLibraryResizeMove = (event: PointerEvent) => {
  const origin = resizeOrigin.value;
  if (!origin) return;

  const deltaX = event.clientX - origin.x;
  const candidateWidth = origin.width + deltaX;

  if (origin.startedCollapsed) {
    if (candidateWidth >= NODE_LIBRARY_MIN_WIDTH + NODE_LIBRARY_COLLAPSE_THRESHOLD) {
      isNodeLibraryCollapsed.value = false;
      nodeLibraryWidth.value = clampNodeLibraryWidth(candidateWidth);
    } else {
      isNodeLibraryCollapsed.value = true;
    }
    return;
  }

  if (candidateWidth < NODE_LIBRARY_MIN_WIDTH - NODE_LIBRARY_COLLAPSE_THRESHOLD) {
    isNodeLibraryCollapsed.value = true;
    return;
  }

  isNodeLibraryCollapsed.value = false;
  nodeLibraryWidth.value = clampNodeLibraryWidth(candidateWidth);
};

const handleNodeLibraryResizeStart = (event: PointerEvent, fromCollapsed = false) => {
  if (event.button !== 0) return;

  event.preventDefault();
  resizeOrigin.value = {
    x: event.clientX,
    width: fromCollapsed ? NODE_LIBRARY_MIN_WIDTH : nodeLibraryWidth.value,
    startedCollapsed: fromCollapsed,
  };
  isResizingNodeLibrary.value = true;
  if (typeof document !== 'undefined') {
    document.body.classList.add('cursor-col-resize', 'select-none');
  }

  if (typeof window !== 'undefined') {
    window.addEventListener('pointermove', handleNodeLibraryResizeMove);
    window.addEventListener('pointerup', stopNodeLibraryResize);
    window.addEventListener('pointercancel', stopNodeLibraryResize);
  }
};

const handleEditorResize = () => {
  nodeLibraryWidth.value = clampNodeLibraryWidth(nodeLibraryWidth.value);
};

const handleBeforeUnload = () => {
  if ((props.saveStatus ?? 'saved') !== 'saved') {
    emit('save_workflow');
  }
};

onMounted(() => {
  if (typeof window === 'undefined') return;

  const storedWidth = Number(window.localStorage.getItem(NODE_LIBRARY_WIDTH_STORAGE_KEY));
  const storedCollapsed =
    window.localStorage.getItem(NODE_LIBRARY_COLLAPSED_STORAGE_KEY) === '1';
  if (Number.isFinite(storedWidth) && storedWidth > 0) {
    nodeLibraryWidth.value = clampNodeLibraryWidth(storedWidth);
  } else {
    nodeLibraryWidth.value = clampNodeLibraryWidth(nodeLibraryWidth.value);
  }
  isNodeLibraryCollapsed.value = storedCollapsed;

  window.addEventListener('resize', handleEditorResize);
  window.addEventListener('beforeunload', handleBeforeUnload);
  lastSavedClock.value = Date.now();
  lastSavedTimer = window.setInterval(() => {
    lastSavedClock.value = Date.now();
  }, 30_000);
});

onBeforeUnmount(() => {
  if (typeof window !== 'undefined') {
    window.removeEventListener('resize', handleEditorResize);
    window.removeEventListener('beforeunload', handleBeforeUnload);
    if (lastSavedTimer !== null) {
      window.clearInterval(lastSavedTimer);
      lastSavedTimer = null;
    }
  }
  stopNodeLibraryResize();
});

// Publish modal state
const isPublishModalOpen = ref(false);
const isPublishing = ref(false);
const isValidatingPublish = ref(false);
const publishError = ref<string | null>(null);
const publishValidationErrors = ref<WorkflowValidationError[]>([]);
const publishTriggerImpact = ref<TriggerImpact | null>(null);
const publishExecutionHashChanged = ref<boolean | null>(null);

function openPublishModal() {
  publishError.value = null;
  publishValidationErrors.value = [];
  publishTriggerImpact.value = null;
  publishExecutionHashChanged.value = null;
  isValidatingPublish.value = true;
  isPublishModalOpen.value = true;
  emit('validate_draft');
}

function closePublishModal() {
  if (!isPublishing.value) {
    isPublishModalOpen.value = false;
    isValidatingPublish.value = false;
  }
}

function handlePublish() {
  isPublishing.value = true;
  publishError.value = null;
  emit('publish_workflow');
}

const editorValidationErrors = computed<WorkflowValidationError[]>(() =>
  Object.values(props.validationErrors ?? {}).flat()
);

const activeToolbarErrors = computed(() =>
  compilationErrors.value.length > 0
    ? compilationErrors.value
    : publishValidationErrors.value.length > 0
      ? publishValidationErrors.value
      : editorValidationErrors.value
);

const toolbarValidationErrors = computed(() =>
  activeToolbarErrors.value.map(error => {
    const location = error.field ? `${error.field}: ` : '';
    return `${location}${error.message}`;
  })
);

const inlineValidationErrors = computed(() => {
  if (compilationErrors.value.length > 0) {
    return compilationErrors.value;
  }

  if (isPublishModalOpen.value || publishValidationErrors.value.length > 0) {
    return [];
  }

  return editorValidationErrors.value;
});

const inlineValidationTitle = computed(() =>
  inlineValidationErrors.value.some(error => error.code === 'compile_error')
    ? 'Execution blocked'
    : 'Draft issues'
);

const formatValidationError = (error: WorkflowValidationError) => {
  const location = error.field ? `${error.field}: ` : '';
  return `${location}${error.message}`;
};

const isDebugMode = computed(() => !!props.debugExecutionId);

const lastSavedClock = ref(Date.now());
let lastSavedTimer: number | null = null;
const relativeTimeFormatter = new Intl.RelativeTimeFormat(undefined, {
  numeric: 'auto',
});
const exactTimestampFormat: Intl.DateTimeFormatOptions = {
  month: 'short',
  day: 'numeric',
  hour: 'numeric',
  minute: '2-digit',
};
const RELATIVE_TIME_STEPS: Array<{
  limit: number;
  divisor: number;
  unit: Intl.RelativeTimeFormatUnit;
}> = [
  { limit: 3600, divisor: 60, unit: 'minute' },
  { limit: 86400, divisor: 3600, unit: 'hour' },
  { limit: 604800, divisor: 86400, unit: 'day' },
  { limit: 2592000, divisor: 604800, unit: 'week' },
  { limit: 31536000, divisor: 2592000, unit: 'month' },
  { limit: Number.POSITIVE_INFINITY, divisor: 31536000, unit: 'year' },
];

const lastSavedAt = computed(() => {
  // Use draft.updated_at (last persist) for "Last saved"; workflow.updated_at only changes on publish/rename
  const dateStr = editor.workflow?.draft?.updated_at ?? editor.workflow?.updated_at;
  if (!dateStr) return null;
  const date = new Date(dateStr);
  return Number.isNaN(date.getTime()) ? null : date;
});

const formatRelativeTimestamp = (date: Date, nowMs: number) => {
  const diffSeconds = Math.floor((nowMs - date.getTime()) / 1000);
  if (diffSeconds < 60) return 'just now';

  const step =
    RELATIVE_TIME_STEPS.find(({ limit }) => diffSeconds < limit) ??
    RELATIVE_TIME_STEPS[RELATIVE_TIME_STEPS.length - 1];

  return relativeTimeFormatter.format(-Math.floor(diffSeconds / step.divisor), step.unit);
};

const lastSaved = computed(() => {
  const date = lastSavedAt.value;
  if (!date) return 'just now';
  return formatRelativeTimestamp(date, lastSavedClock.value);
});

const lastSavedExact = computed(() => {
  const date = lastSavedAt.value;
  if (!date) return 'Saved just now';
  return `Saved ${date.toLocaleString(undefined, exactTimestampFormat)}`;
});

const saveStatus = computed(() => props.saveStatus ?? 'saved');
const saveIndicatorDetail = computed(() => {
  switch (saveStatus.value) {
    case 'saving':
      return 'Saving\u2026';
    case 'error':
      return 'Save failed \u00b7 retrying';
    default:
      return `Saved ${lastSaved.value}`;
  }
});
const saveIndicatorTitle = computed(() => {
  switch (saveStatus.value) {
    case 'saving':
      return 'Saving workflow draft';
    case 'error':
      return props.saveError ?? 'Saving failed. Retrying automatically.';
    default:
      return lastSavedExact.value;
  }
});
const saveIndicatorDotClass = computed(() => {
  switch (saveStatus.value) {
    case 'saving':
      return 'bg-amber-500 animate-pulse';
    case 'error':
      return 'bg-rose-500';
    default:
      return 'bg-emerald-500';
  }
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
  pending: { dotClass: 'bg-base-content/40', label: 'Pending' },
  running: { dotClass: 'bg-primary', label: 'Running' },
  paused: { dotClass: 'bg-warning', label: 'Paused' },
  completed: { dotClass: 'bg-success', label: 'Completed' },
  failed: { dotClass: 'bg-error', label: 'Failed' },
  cancelled: { dotClass: 'bg-base-content/40', label: 'Cancelled' },
  timeout: { dotClass: 'bg-warning', label: 'Timeout' },
} as const;
const debugStatusBadge = computed(() => {
  const key = debugExecutionStatus.value as keyof typeof debugStatusConfig;
  return debugStatusConfig[key] ?? debugStatusConfig.pending;
});
const debugExecutionLink = computed(() => {
  const workflow = editor.workflow as any;
  if (!workflow?.id || !workflow?.project_id || !props.debugExecutionId) return null;
  return `/projects/${workflow.project_id}/workflows/${workflow.id}/runs/${props.debugExecutionId}`;
});
const workflowExecutionsLink = computed(() => {
  const workflow = editor.workflow as any;
  if (!workflow?.id || !workflow?.project_id) return null;
  return `/projects/${workflow.project_id}/workflows/${workflow.id}`;
});
const debugExitLink = computed(() => {
  const workflow = editor.workflow as any;
  if (!workflow?.id || !workflow?.project_id) return null;
  return `/projects/${workflow.project_id}/workflows/${workflow.id}/edit`;
});
const workflowStatus = computed<'draft' | 'active' | 'archived'>(() => {
  const workflow = editor.workflow;

  if (workflow?.archived_at) {
    return 'archived';
  }

  if (workflow?.draft?.status === 'draft') {
    return 'draft';
  }

  return 'active';
});
const publishVersionNumber = computed(() => editor.workflow?.draft?.version ?? null);

useLiveEvent<{
  valid: boolean;
  validation_errors?: WorkflowValidationError[];
  trigger_impact?: TriggerImpact | null;
  execution_hash_changed?: boolean | null;
  error?: string;
}>('workflow:validation_result', payload => {
  isValidatingPublish.value = false;
  publishValidationErrors.value = payload.validation_errors ?? [];
  publishTriggerImpact.value = payload.trigger_impact ?? null;
  publishExecutionHashChanged.value = payload.execution_hash_changed ?? null;
  publishError.value = payload.error ?? null;
});

useLiveEvent<{
  errors?: Array<{
    step_id?: string | null;
    message?: string;
  }>;
}>('compilation_errors', payload => {
  compilationErrors.value = (payload.errors ?? []).map(error => ({
    step_id: error.step_id ?? null,
    field: null,
    message: error.message ?? 'Compilation failed',
    severity: 'error',
    code: 'compile_error',
  }));
});

useLiveEvent<{
  success: boolean;
  error?: string;
  validation_errors?: WorkflowValidationError[];
  trigger_impact?: TriggerImpact | null;
  execution_hash_changed?: boolean | null;
}>(
  'workflow:publish_result',
  payload => {
    isPublishing.value = false;
    if (payload.success) {
      isPublishModalOpen.value = false;
      publishValidationErrors.value = [];
      publishTriggerImpact.value = null;
      publishExecutionHashChanged.value = null;
      publishError.value = null;
      return;
    }

    publishValidationErrors.value = payload.validation_errors ?? [];
    publishTriggerImpact.value = payload.trigger_impact ?? null;
    publishExecutionHashChanged.value = payload.execution_hash_changed ?? null;
    publishError.value =
      payload.error ??
      (publishValidationErrors.value.length > 0 ? 'Fix validation errors before publishing.' : null);
  }
);
</script>

<template>
  <div class="bg-base-100 text-base-content flex h-screen overflow-hidden font-sans">
    <NodeLibrary
      v-if="!isNodeLibraryCollapsed"
      :library-items="editor.nodeLibraryItems"
      :workflow-name="editor.workflow?.name ?? 'Untitled Workflow'"
      :workflow-status="workflowStatus"
      :style="{ width: `${nodeLibraryWidth}px` }"
      class="z-20 shrink-0 relative"
      @resize-start="handleNodeLibraryResizeStart"
      @toggle-collapse="toggleNodeLibraryCollapsed"
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
        @click="toggleNodeLibraryCollapsed"
      >
        <ChevronDoubleRightIcon class="h-4 w-4" />
      </button>

      <div
        class="absolute inset-y-0 -right-4 w-8 cursor-col-resize touch-none"
        role="separator"
        aria-label="Resize node library panel"
        aria-orientation="vertical"
        @pointerdown.stop="handleNodeLibraryResizeStart($event, true)"
      />
    </div>

    <div class="relative flex min-w-0 flex-1 flex-col pt-3.5">
      <div
        v-if="!isNodeLibraryCollapsed"
        class="absolute inset-y-0 -left-4 z-40 w-12 cursor-col-resize touch-none"
        role="separator"
        aria-label="Resize node library panel"
        aria-orientation="vertical"
        @pointerdown.stop="handleNodeLibraryResizeStart"
      />

      <div class="absolute right-0 top-[14px] z-30 flex items-start">
        <EditorToolbar
          :can-undo="editor.canUndo"
          :can-redo="editor.canRedo"
          :undo-tooltip="editor.undoTooltip"
          :redo-tooltip="editor.redoTooltip"
          :is-undo-pending="editor.isUndoPending"
          :validation-errors="toolbarValidationErrors"
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
        <div class="pointer-events-none absolute left-6 top-5 z-30 flex select-none flex-col items-start gap-0.5">
          <div class="px-1.5 py-0.5">
            <div class="flex items-center gap-2">
              <a
                :href="`/projects/${(editor.workflow as any)?.project_id}`"
                class="pointer-events-auto select-none text-base-content/60 hover:text-base-content/80 text-xs font-medium transition-colors"
              >
                {{ (editor.workflow as any)?.project?.name || 'project' }}
              </a>
              <SlashIcon class="pointer-events-none text-base-content/30 h-3.5 w-3.5" stroke-width="2.5" />
              <span class="pointer-events-none text-base-content/90 text-xs font-semibold">
                {{ editor.workflow?.name ?? 'Untitled Workflow' }}
              </span>
              <div class="pointer-events-none ml-1 flex items-center">
                <Avatar :presences="editor.presences" class="scale-95" />
              </div>
            </div>
          </div>

          <p
            class="pointer-events-auto ml-2 select-none text-[11px] tracking-wide text-base-content/60"
            :title="saveIndicatorTitle"
          >
            <span class="inline-block h-1 w-1 rounded-full align-middle mr-1.5" :class="saveIndicatorDotClass"></span>
            <span>{{ saveIndicatorDetail }}</span>
          </p>

          <!-- Debug Mode Floating Pill -->
          <div
            v-if="isDebugMode"
            class="pointer-events-auto mt-2 flex flex-col gap-1.5 rounded-xl border border-base-300/50 bg-base-100/80 px-3 py-2.5 shadow-sm backdrop-blur-sm"
          >
            <div class="flex items-center gap-2 text-[11px]">
              <BugAntIcon class="h-3.5 w-3.5 text-base-content/50" />
              <span class="font-semibold text-base-content/70">Debug</span>
              <span class="text-base-content/30">&middot;</span>
              <span class="flex items-center gap-1.5">
                <span
                  class="inline-block h-1.5 w-1.5 rounded-full"
                  :class="debugStatusBadge.dotClass"
                ></span>
                <span class="font-medium text-base-content/60">{{ debugStatusBadge.label }}</span>
              </span>
              <span class="text-base-content/30">&middot;</span>
              <span class="font-mono text-base-content/50">{{ debugExecutionShortId }}</span>
            </div>
            <div class="flex items-center gap-3">
              <p v-if="debugExecutionTimestamp" class="text-[10px] text-base-content/40">
                {{ debugExecutionTimestamp }}
              </p>
              <div class="flex items-center gap-1.5">
                <a
                  v-if="debugExecutionLink"
                  :href="debugExecutionLink"
                  class="rounded-lg px-2 py-0.5 text-[10px] font-medium text-base-content/50 transition-colors hover:bg-base-200/80 hover:text-base-content/70"
                >
                  View execution
                </a>
                <a
                  v-if="debugExitLink"
                  :href="debugExitLink"
                  class="rounded-lg bg-primary/10 px-2 py-0.5 text-[10px] font-medium text-primary transition-colors hover:bg-primary/20"
                >
                  Exit debug
                </a>
              </div>
            </div>
          </div>

          <div
            v-if="inlineValidationErrors.length > 0"
            class="pointer-events-auto mt-3 max-w-lg rounded-2xl border border-error/20 bg-error/6 px-4 py-3 shadow-sm backdrop-blur-sm"
          >
            <div class="flex items-center gap-2 text-[11px] font-semibold text-error/80">
              <ExclamationCircleIcon class="h-4 w-4" />
              <span>{{ inlineValidationTitle }}</span>
              <span class="text-error/35">&middot;</span>
              <span class="font-medium">{{ inlineValidationErrors.length }} issue<span v-if="inlineValidationErrors.length !== 1">s</span></span>
            </div>
            <ul class="mt-2 space-y-1.5">
              <li
                v-for="(error, index) in inlineValidationErrors.slice(0, 3)"
                :key="`${error.code}-${error.step_id ?? 'global'}-${index}`"
                class="text-[11px] leading-relaxed text-error/75"
              >
                {{ formatValidationError(error) }}
              </li>
            </ul>
            <p
              v-if="inlineValidationErrors.length > 3"
              class="mt-2 text-[10px] font-medium uppercase tracking-[0.16em] text-error/45"
            >
              + {{ inlineValidationErrors.length - 3 }} more
            </p>
          </div>
        </div>

        <div class="relative flex min-w-0 flex-1 flex-col">
          <div class="relative flex min-w-0 flex-1 flex-col overflow-hidden">
            <WorkflowCanvas
              :nodes="editor.nodes"
              :edges="editor.edges"
              :node-types="editor.nodeTypes"
              :edge-types="editor.edgeTypes"
              :snap-enabled="editor.store.snapEnabled"
              :grid-size="editor.gridSize"
              :effective-snap-to-grid="editor.effectiveSnapToGrid"
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
              :handle-pane-mouse-leave="editor.handlePaneMouseLeave"
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
              :workflow-executions-link="workflowExecutionsLink"
              :on-run-test="editor.handleRunTest"
              :on-cancel-execution="editor.handleCancelExecution"
              :on-toggle-snap="editor.store.toggleSnap"
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
        :is-open="isPublishModalOpen"
        :workflow-name="editor.workflow?.name ?? 'Workflow'"
        :version-number="publishVersionNumber"
        :is-publishing="isPublishing"
        :is-validating="isValidatingPublish"
        :publish-error="publishError"
        :validation-errors="publishValidationErrors"
        :trigger-impact="publishTriggerImpact"
        :execution-hash-changed="publishExecutionHashChanged"
        @close="closePublishModal"
        @publish="handlePublish"
      />
    </div>
  </div>
</template>
