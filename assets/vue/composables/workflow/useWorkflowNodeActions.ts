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

  const handleMoveSteps = (stepPositions: Record<string, XYPosition>) => {
    Object.entries(stepPositions).forEach(([stepId, position]) => {
      options.emit('move_step', { step_id: stepId, position });
    });
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
    }
  ) => {
    options.emit('update_group', { group_id: groupId, changes });
  };

  return {
    handleRunNode,
    handleMoveSteps,
    handleUpdateStep,
    handleUpdateGroup,
  };
}
