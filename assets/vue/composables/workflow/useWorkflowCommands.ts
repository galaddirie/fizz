import type { XYPosition } from "@vue-flow/core";

import type {
  StepConfigPinOutputPayload,
  StepConfigPreviewExpressionPayload,
  StepConfigSavePayload,
} from "@/components/flow/step_config/contracts";
import type {
  WorkflowEditorAction,
  WorkflowEditorDispatch,
} from "@/features/workflow-editor/contracts/workflowEditor";
import type {
  WorkflowGroupChanges,
  WorkflowStepChanges,
} from "@/shared/ui/workflow-scene/types";
import type { StepExecution } from "@/types/workflow";

type OutputPinPayload = Extract<
  WorkflowEditorAction,
  { type: "document.output.pin" }
>["payload"];

interface UseWorkflowCommandsOptions {
  canEdit: () => boolean;
  dispatch: WorkflowEditorDispatch;
  stepExecutions: () => StepExecution[];
  requestNodeRemoval: (stepId: string) => void;
  selectNode: (stepId: string | null) => void;
}

const runIfEditable = (canEdit: () => boolean, operation: () => void) => {
  if (!canEdit()) return;
  operation();
};

const toTimestampMs = (value: unknown) => {
  if (!value) return 0;
  if (value instanceof Date) return value.getTime();
  if (typeof value !== "string") return 0;

  const parsed = Date.parse(value);
  return Number.isNaN(parsed) ? 0 : parsed;
};

const selectMoreRecentExecution = (
  best: StepExecution | null,
  candidate: StepExecution
) => {
  if (!best) return candidate;

  const bestTime = toTimestampMs(
    best.completed_at ?? best.started_at ?? best.inserted_at
  );
  const candidateTime = toTimestampMs(
    candidate.completed_at ?? candidate.started_at ?? candidate.inserted_at
  );

  return candidateTime >= bestTime ? candidate : best;
};

const buildLatestPinPayload = (
  stepExecutions: StepExecution[],
  stepId: string,
  itemIndex?: number | null
): OutputPinPayload => {
  const executions = stepExecutions.filter(
    (execution) => execution.step_id === stepId
  );
  if (!executions.length) return { step_id: stepId };

  const executionsForItem =
    itemIndex === null || itemIndex === undefined
      ? executions
      : executions.filter((execution) => execution.item_index === itemIndex);
  const fallbackPool = executionsForItem.length
    ? executionsForItem
    : executions;
  const completedExecutions = fallbackPool.filter(
    (execution) => execution.status === "completed"
  );
  const latestExecution = (
    completedExecutions.length ? completedExecutions : fallbackPool
  ).reduce(selectMoreRecentExecution, null);

  if (!latestExecution) return { step_id: stepId };

  return {
    step_id: stepId,
    output_data: latestExecution.output_data ?? null,
    item_index: latestExecution.item_index ?? null,
  };
};

const dispatchStepMove = (
  dispatch: WorkflowEditorDispatch,
  stepPositions: Record<string, XYPosition>
) => {
  const entries = Object.entries(stepPositions);
  if (entries.length === 0) return;

  if (entries.length === 1) {
    const [stepId, position] = entries[0];
    dispatch({
      type: "document.step.move",
      payload: { step_id: stepId, position },
    });
    return;
  }

  dispatch({
    type: "document.step.moveMany",
    payload: { step_positions: stepPositions },
  });
};

export function useWorkflowCommands(options: UseWorkflowCommandsOptions) {
  const document = {
    save: () =>
      runIfEditable(options.canEdit, () => {
        options.dispatch({ type: "document.save" });
      }),
  };

  const execution = {
    runTest: () =>
      runIfEditable(options.canEdit, () => {
        options.dispatch({ type: "execution.runTest" });
      }),
    cancel: () => {
      options.dispatch({ type: "execution.cancel" });
    },
  };

  const selection = {
    selectStep: (stepId: string | null) => {
      options.selectNode(stepId);
    },
  };

  const inspector = {
    saveStepConfig: (payload: StepConfigSavePayload) =>
      runIfEditable(options.canEdit, () => {
        options.dispatch({
          type: "document.step.update",
          payload: {
            step_id: payload.id,
            changes: {
              name: payload.name,
              config: payload.config,
              notes: payload.notes,
            },
          },
        });
      }),
    deleteStep: (stepId: string) =>
      runIfEditable(options.canEdit, () => {
        options.requestNodeRemoval(stepId);
      }),
    previewExpression: (payload: StepConfigPreviewExpressionPayload) => {
      options.dispatch({ type: "inspector.previewExpression", payload });
    },
    pinOutput: (payload: StepConfigPinOutputPayload) =>
      runIfEditable(options.canEdit, () => {
        if (!payload.step_id) return;

        options.dispatch({
          type: "document.output.pin",
          payload: {
            step_id: payload.step_id,
            output_data: payload.output_data ?? null,
            item_index: payload.item_index ?? null,
          },
        });
      }),
    unpinOutput: (stepId: string) =>
      runIfEditable(options.canEdit, () => {
        if (!stepId) return;
        options.dispatch({
          type: "document.output.unpin",
          payload: { step_id: stepId },
        });
      }),
  };

  const step = {
    run: (stepId: string) =>
      runIfEditable(options.canEdit, () => {
        options.dispatch({
          type: "execution.runNode",
          payload: { step_id: stepId },
        });
      }),
    update: (stepId: string, changes: WorkflowStepChanges) =>
      runIfEditable(options.canEdit, () => {
        options.dispatch({
          type: "document.step.update",
          payload: { step_id: stepId, changes },
        });
      }),
    toggleDisabled: (stepId: string, isDisabled: boolean) =>
      runIfEditable(options.canEdit, () => {
        if (isDisabled) {
          options.dispatch({
            type: "document.step.enable",
            payload: { step_id: stepId },
          });
          return;
        }

        options.dispatch({
          type: "document.step.disable",
          payload: { step_id: stepId, mode: "skip" },
        });
      }),
    togglePin: (stepId: string, isPinned: boolean) => {
      if (isPinned) {
        inspector.unpinOutput(stepId);
        return;
      }

      runIfEditable(options.canEdit, () => {
        options.dispatch({
          type: "document.output.pin",
          payload: buildLatestPinPayload(options.stepExecutions(), stepId),
        });
      });
    },
  };

  const group = {
    update: (groupId: string, changes: WorkflowGroupChanges) =>
      runIfEditable(options.canEdit, () => {
        options.dispatch({
          type: "document.group.update",
          payload: { group_id: groupId, changes },
        });
      }),
    moveSteps: (stepPositions: Record<string, XYPosition>) =>
      runIfEditable(options.canEdit, () => {
        dispatchStepMove(options.dispatch, stepPositions);
      }),
  };

  return {
    document,
    execution,
    selection,
    inspector,
    step,
    group,
  };
}
