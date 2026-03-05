import { describe, expect, it, vi } from 'vitest';

import type { WorkflowEditorDispatch } from '@/features/workflow-editor/contracts/workflowEditor';
import { useWorkflowNodeActions } from './useWorkflowNodeActions';

describe('useWorkflowNodeActions', () => {
  it('routes move and toggle events to the right editor emitters', () => {
    const dispatch = vi.fn() as WorkflowEditorDispatch;

    const actions = useWorkflowNodeActions({
      canEdit: () => true,
      dispatch,
    });

    actions.handleRunNode('step-1');
    actions.handleToggleDisabled('step-1', true);
    actions.handleToggleDisabled('step-2', false);
    actions.handleMoveSteps({ 'step-1': { x: 10, y: 20 } });
    actions.handleMoveSteps({
      'step-1': { x: 10, y: 20 },
      'step-2': { x: 30, y: 40 },
    });
    actions.handleUpdateStep('step-1', { name: 'Updated Name' });
    actions.handleUpdateGroup('group-1', { collapsed: true, color: '#fff' });

    expect(dispatch).toHaveBeenCalledWith({
      type: 'execution.runNode',
      payload: { step_id: 'step-1' },
    });
    expect(dispatch).toHaveBeenCalledWith({
      type: 'document.step.enable',
      payload: { step_id: 'step-1' },
    });
    expect(dispatch).toHaveBeenCalledWith({
      type: 'document.step.disable',
      payload: { step_id: 'step-2', mode: 'skip' },
    });
    expect(dispatch).toHaveBeenCalledWith({
      type: 'document.step.move',
      payload: {
        step_id: 'step-1',
        position: { x: 10, y: 20 },
      },
    });
    expect(dispatch).toHaveBeenCalledWith({
      type: 'document.step.moveMany',
      payload: {
        step_positions: {
          'step-1': { x: 10, y: 20 },
          'step-2': { x: 30, y: 40 },
        },
      },
    });
    expect(dispatch).toHaveBeenCalledWith({
      type: 'document.step.update',
      payload: {
        step_id: 'step-1',
        changes: { name: 'Updated Name' },
      },
    });
    expect(dispatch).toHaveBeenCalledWith({
      type: 'document.group.update',
      payload: {
        group_id: 'group-1',
        changes: { collapsed: true, color: '#fff' },
      },
    });
  });

  it('does not emit run or toggle events when editing is disabled', () => {
    const dispatch = vi.fn() as WorkflowEditorDispatch;

    const actions = useWorkflowNodeActions({
      canEdit: () => false,
      dispatch,
    });

    actions.handleRunNode('step-1');
    actions.handleToggleDisabled('step-1', true);
    actions.handleMoveSteps({});

    expect(dispatch).not.toHaveBeenCalled();
  });
});
