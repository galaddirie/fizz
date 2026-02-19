import type { StepExecution } from '@/types/workflow';
import type { WorkflowEditorEmits } from '@/types/workflowEditor';

type PinPayload = { step_id: string; output_data?: unknown; item_index?: number | null };

interface UseWorkflowPinsOptions {
  stepExecutions: () => StepExecution[];
  emit: WorkflowEditorEmits;
}

export function useWorkflowPins(options: UseWorkflowPinsOptions) {
  const toTimestamp = (value: unknown) => {
    if (!value) return 0;
    if (value instanceof Date) return value.getTime();
    if (typeof value === 'string') {
      const parsed = Date.parse(value);
      return Number.isNaN(parsed) ? 0 : parsed;
    }
    return 0;
  };

  const resolvePinExecution = (stepId: string, itemIndex?: number | null) => {
    const executions = options.stepExecutions().filter(se => se.step_id === stepId);
    if (!executions.length) return null;

    const filtered =
      itemIndex === null || itemIndex === undefined
        ? executions
        : executions.filter(se => se.item_index === itemIndex);
    const candidates = filtered.length ? filtered : executions;
    const completed = candidates.filter(se => se.status === 'completed');
    const pool = completed.length ? completed : candidates;

    return pool.reduce<StepExecution | null>((best, current) => {
      if (!best) return current;
      const bestTime = toTimestamp(best.completed_at ?? best.started_at ?? best.inserted_at);
      const currentTime = toTimestamp(current.completed_at ?? current.started_at ?? current.inserted_at);
      return currentTime >= bestTime ? current : best;
    }, null);
  };

  const buildPinPayload = (stepId: string, itemIndex?: number | null) => {
    const execution = resolvePinExecution(stepId, itemIndex);
    if (!execution) return { step_id: stepId };

    return {
      step_id: stepId,
      output_data: execution.output_data ?? null,
      item_index: execution.item_index ?? null,
    };
  };

  const emitPinOutput = (stepId: string, itemIndex?: number | null) => {
    options.emit('pin_output', buildPinPayload(stepId, itemIndex));
  };

  const handlePinOutput = (payload: PinPayload) => {
    if (!payload || !payload.step_id) return;
    const hasOutputData = Object.prototype.hasOwnProperty.call(payload, 'output_data');

    if (hasOutputData) {
      options.emit('pin_output', {
        step_id: payload.step_id,
        output_data: payload.output_data ?? null,
        item_index: payload.item_index ?? null,
      });
      return;
    }

    emitPinOutput(payload.step_id, payload.item_index);
  };

  const handleUnpinOutput = (payload: { step_id: string }) => {
    if (!payload?.step_id) return;
    options.emit('unpin_output', { step_id: payload.step_id });
  };

  const handleTogglePin = (stepId: string, isPinned: boolean) => {
    if (isPinned) {
      options.emit('unpin_output', { step_id: stepId });
      return;
    }

    emitPinOutput(stepId);
  };

  return {
    handlePinOutput,
    handleUnpinOutput,
    handleTogglePin,
  };
}
