import type { XYPosition } from '@vue-flow/core';

import type { Step } from '@/types/workflow';
import type { WorkflowEditorEmits } from '@/types/workflowEditor';

interface UseWorkflowNodeActionsOptions {
  canEdit: () => boolean;
  emit: WorkflowEditorEmits;
}

export function useWorkflowNodeActions(options: UseWorkflowNodeActionsOptions) {
  const handleRunNode = (stepId: string) => {
    if (!options.canEdit()) return;
    options.emit('run_node', { step_id: stepId });
  };

  const handleToggleDisabled = (stepId: string, isDisabled: boolean) => {
    if (!options.canEdit()) return;

    if (isDisabled) {
      options.emit('enable_step', { step_id: stepId });
      return;
    }

    options.emit('disable_step', { step_id: stepId, mode: 'skip' });
  };

  const handleMoveSteps = (stepPositions: Record<string, XYPosition>) => {
    const entries = Object.entries(stepPositions);
    if (entries.length === 0) return;

    if (entries.length === 1) {
      const [stepId, position] = entries[0];
      options.emit('move_step', { step_id: stepId, position });
      return;
    }

    options.emit('move_steps', { step_positions: stepPositions });
  };

  const handleUpdateStep = (stepId: string, changes: Partial<Step>) => {
    options.emit('update_step', { step_id: stepId, changes });
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
    options.emit('update_group', { group_id: groupId, changes });
  };

  return {
    handleRunNode,
    handleToggleDisabled,
    handleMoveSteps,
    handleUpdateStep,
    handleUpdateGroup,
  };
}
