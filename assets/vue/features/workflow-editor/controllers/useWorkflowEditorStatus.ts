import { computed, onBeforeUnmount, onMounted, ref } from 'vue';

import type { WorkflowEditorViewProps } from '../contracts/workflowEditor';

const relativeTimeFormatter = new Intl.RelativeTimeFormat(undefined, {
  numeric: 'auto',
});

const exactTimestampFormat: Intl.DateTimeFormatOptions = {
  month: 'short',
  day: 'numeric',
  hour: 'numeric',
  minute: '2-digit',
};

const relativeTimeSteps: Array<{
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

const debugStatusConfig = {
  pending: { dotClass: 'bg-base-content/40', label: 'Pending' },
  running: { dotClass: 'bg-primary', label: 'Running' },
  paused: { dotClass: 'bg-warning', label: 'Paused' },
  completed: { dotClass: 'bg-success', label: 'Completed' },
  failed: { dotClass: 'bg-error', label: 'Failed' },
  cancelled: { dotClass: 'bg-base-content/40', label: 'Cancelled' },
  timeout: { dotClass: 'bg-warning', label: 'Timeout' },
} as const;

export function useWorkflowEditorStatus(props: WorkflowEditorViewProps) {
  const workflow = computed(() => props.document.workflow);
  const execution = computed(() => props.execution.execution);
  const lastSavedClock = ref(Date.now());
  let lastSavedTimer: number | null = null;

  const lastSavedAt = computed(() => {
    const dateStr = workflow.value.draft?.updated_at ?? workflow.value.updated_at;
    if (!dateStr) return null;

    const date = new Date(dateStr);
    return Number.isNaN(date.getTime()) ? null : date;
  });

  const formatRelativeTimestamp = (date: Date, nowMs: number) => {
    const diffSeconds = Math.floor((nowMs - date.getTime()) / 1000);
    if (diffSeconds < 60) return 'just now';

    const step =
      relativeTimeSteps.find(({ limit }) => diffSeconds < limit) ??
      relativeTimeSteps[relativeTimeSteps.length - 1];

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

  const isDebugMode = computed(() => !!props.execution.debugExecutionId);
  const debugExecutionShortId = computed(() => {
    const id = props.execution.debugExecutionId ?? execution.value?.id ?? '';
    return id ? id.slice(0, 8) : '';
  });
  const debugExecutionTimestamp = computed(() => {
    const timestamp = execution.value?.started_at ?? execution.value?.inserted_at;
    if (!timestamp) return null;

    const date = new Date(timestamp);
    if (Number.isNaN(date.getTime())) return null;
    return date.toLocaleString();
  });
  const debugExecutionStatus = computed(() => execution.value?.status ?? 'pending');
  const debugStatusBadge = computed(() => {
    const key = debugExecutionStatus.value as keyof typeof debugStatusConfig;
    return debugStatusConfig[key] ?? debugStatusConfig.pending;
  });

  const workspaceLink = computed(() => {
    if (!workflow.value.workspace_id) return null;
    return `/workspaces/${workflow.value.workspace_id}`;
  });

  const workflowExecutionsLink = computed(() => {
    if (!workflow.value.id || !workflow.value.workspace_id) return null;
    return `/workspaces/${workflow.value.workspace_id}/workflows/${workflow.value.id}`;
  });

  const debugExecutionLink = computed(() => {
    if (!workflowExecutionsLink.value || !props.execution.debugExecutionId) return null;
    return `${workflowExecutionsLink.value}/execution/${props.execution.debugExecutionId}`;
  });

  const debugExitLink = computed(() => {
    if (!workflowExecutionsLink.value) return null;
    return `${workflowExecutionsLink.value}/edit`;
  });

  onMounted(() => {
    lastSavedClock.value = Date.now();
    lastSavedTimer = window.setInterval(() => {
      lastSavedClock.value = Date.now();
    }, 30_000);
  });

  onBeforeUnmount(() => {
    if (typeof window !== 'undefined' && lastSavedTimer !== null) {
      window.clearInterval(lastSavedTimer);
      lastSavedTimer = null;
    }
  });

  return {
    workflow,
    workspaceLink,
    workflowExecutionsLink,
    lastSaved,
    lastSavedExact,
    isDebugMode,
    debugExecutionShortId,
    debugExecutionTimestamp,
    debugStatusBadge,
    debugExecutionLink,
    debugExitLink,
  };
}
