const TRACE_STORAGE_KEY = 'fizz.workflow.trace';
const TRACE_EVENT_NAME = 'fizz:workflow-trace';
const TRACE_BUFFER_LIMIT = 200;

type WorkflowTraceEntry = {
  event: string;
  at: string;
} & Record<string, unknown>;

declare global {
  interface Window {
    __fizzWorkflowTrace__?: WorkflowTraceEntry[];
  }
}

const traceEnabled = () => {
  if (typeof window === 'undefined') return false;
  const raw = window.localStorage.getItem(TRACE_STORAGE_KEY);
  if (!raw) return false;

  const normalized = raw.trim().toLowerCase();
  return normalized === '1' || normalized === 'true' || normalized === 'on' || normalized === 'debug';
};

export const workflowTrace = (event: string, payload: Record<string, unknown> = {}) => {
  if (!traceEnabled()) return;

  const entry: WorkflowTraceEntry = {
    event,
    at: new Date().toISOString(),
    ...payload,
  };

  window.__fizzWorkflowTrace__ = [...(window.__fizzWorkflowTrace__ ?? []), entry].slice(
    -TRACE_BUFFER_LIMIT,
  );
  window.dispatchEvent(new CustomEvent<WorkflowTraceEntry>(TRACE_EVENT_NAME, { detail: entry }));
};
