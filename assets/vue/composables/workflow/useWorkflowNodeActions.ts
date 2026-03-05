import type { XYPosition } from '@vue-flow/core';

import type { WorkflowEditorDispatch } from '@/features/workflow-editor/contracts/workflowEditor';
import type { Step } from '@/types/workflow';

interface UseWorkflowNodeActionsOptions {
  canEdit: () => boolean;
  dispatch: WorkflowEditorDispatch;
}

export function useWorkflowNodeActions(options: UseWorkflowNodeActionsOptions) {
  const handleRunNode = (stepId: string) => {
    if (!options.canEdit()) return;
    options.dispatch({ type: 'execution.runNode', payload: { step_id: stepId } });
  };

  const handleToggleDisabled = (stepId: string, isDisabled: boolean) => {
    if (!options.canEdit()) return;

    if (isDisabled) {
      options.dispatch({ type: 'document.step.enable', payload: { step_id: stepId } });
      return;
    }

    options.dispatch({
      type: 'document.step.disable',
      payload: { step_id: stepId, mode: 'skip' },
    });
  };

  const handleMoveSteps = (stepPositions: Record<string, XYPosition>) => {
    const entries = Object.entries(stepPositions);
    if (entries.length === 0) return;

    if (entries.length === 1) {
      const [stepId, position] = entries[0];
      options.dispatch({ type: 'document.step.move', payload: { step_id: stepId, position } });
      return;
    }

    options.dispatch({ type: 'document.step.moveMany', payload: { step_positions: stepPositions } });
  };

  const handleUpdateStep = (stepId: string, changes: Partial<Step>) => {
    options.dispatch({ type: 'document.step.update', payload: { step_id: stepId, changes } });
  };

  const handleUpdateGroup = (
    groupId: string,
    changes: {
      name?: string;
      position?: { x?: number; y?: number; width?: number; height?: number };
      collapsed?: boolean;
      output_step_id?: string;
      color?: string;
      font_size?: number;
    }
  ) => {
    options.dispatch({ type: 'document.group.update', payload: { group_id: groupId, changes } });
  };

  return {
    handleRunNode,
    handleToggleDisabled,
    handleMoveSteps,
    handleUpdateStep,
    handleUpdateGroup,
  };
}
