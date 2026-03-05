import { describe, expect, it, vi } from 'vitest';

import { useWorkflowNodeActions } from './useWorkflowNodeActions';
import type { WorkflowEditorEmits } from '@/types/workflowEditor';

describe('useWorkflowNodeActions', () => {
  it('routes move and toggle events to the right editor emitters', () => {
    const emit = vi.fn() as unknown as WorkflowEditorEmits;

    const actions = useWorkflowNodeActions({
      canEdit: () => true,
      emit,
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

    expect(emit).toHaveBeenCalledWith('run_node', { step_id: 'step-1' });
    expect(emit).toHaveBeenCalledWith('enable_step', { step_id: 'step-1' });
    expect(emit).toHaveBeenCalledWith('disable_step', { step_id: 'step-2', mode: 'skip' });
    expect(emit).toHaveBeenCalledWith('move_step', {
      step_id: 'step-1',
      position: { x: 10, y: 20 },
    });
    expect(emit).toHaveBeenCalledWith('move_steps', {
      step_positions: {
        'step-1': { x: 10, y: 20 },
        'step-2': { x: 30, y: 40 },
      },
    });
    expect(emit).toHaveBeenCalledWith('update_step', {
      step_id: 'step-1',
      changes: { name: 'Updated Name' },
    });
    expect(emit).toHaveBeenCalledWith('update_group', {
      group_id: 'group-1',
      changes: { collapsed: true, color: '#fff' },
    });
  });

  it('does not emit run or toggle events when editing is disabled', () => {
    const emit = vi.fn() as unknown as WorkflowEditorEmits;

    const actions = useWorkflowNodeActions({
      canEdit: () => false,
      emit,
    });

    actions.handleRunNode('step-1');
    actions.handleToggleDisabled('step-1', true);
    actions.handleMoveSteps({});

    expect(emit).not.toHaveBeenCalled();
  });
});
