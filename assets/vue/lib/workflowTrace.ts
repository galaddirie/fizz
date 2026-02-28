const TRACE_STORAGE_KEY = 'fizz.workflow.trace';

const traceEnabled = () => {
  if (typeof window === 'undefined') return false;
  const raw = window.localStorage.getItem(TRACE_STORAGE_KEY);
  if (!raw) return false;

  const normalized = raw.trim().toLowerCase();
  return normalized === '1' || normalized === 'true' || normalized === 'on' || normalized === 'debug';
};

export const workflowTrace = (event: string, payload: Record<string, unknown> = {}) => {
  if (!traceEnabled()) return;

  console.debug('[workflow-trace]', {
    event,
    at: new Date().toISOString(),
    ...payload,
  });
};

