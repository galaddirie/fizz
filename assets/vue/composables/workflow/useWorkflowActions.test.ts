import { describe, expect, it, vi } from 'vitest';

import { useWorkflowActions } from './useWorkflowActions';
import type { WorkflowEditorEmits } from '@/types/workflowEditor';

describe('useWorkflowActions', () => {
  it('emits workflow updates only when editing is enabled', () => {
    const emit = vi.fn() as unknown as WorkflowEditorEmits;
    const requestNodeRemoval = vi.fn();
    const selectNode = vi.fn();

    const actions = useWorkflowActions({
      canEdit: () => true,
      emit,
      requestNodeRemoval,
      selectNode,
    });

    actions.handleSaveConfig({
      id: 'step-1',
      name: 'Fetch User',
      config: { method: 'GET' },
      notes: 'Pull the latest profile',
    });
    actions.handleDeleteStep('step-1');
    actions.handleSave();
    actions.handleRunTest();
    actions.handleCancelExecution();
    actions.handlePreviewExpression({
      step_id: 'step-1',
      field_key: 'config.url',
      expression: '{{ trigger.url }}',
    });
    actions.selectTraceStep('step-1');

    expect(emit).toHaveBeenCalledWith('update_step', {
      step_id: 'step-1',
      changes: {
        name: 'Fetch User',
        config: { method: 'GET' },
        notes: 'Pull the latest profile',
      },
    });
    expect(requestNodeRemoval).toHaveBeenCalledWith('step-1');
    expect(emit).toHaveBeenCalledWith('save_workflow');
    expect(emit).toHaveBeenCalledWith('run_test');
    expect(emit).toHaveBeenCalledWith('cancel_execution');
    expect(emit).toHaveBeenCalledWith('preview_expression', {
      step_id: 'step-1',
      field_key: 'config.url',
      expression: '{{ trigger.url }}',
    });
    expect(selectNode).toHaveBeenCalledWith('step-1');
  });

  it('guards mutating actions when editing is disabled', () => {
    const emit = vi.fn() as unknown as WorkflowEditorEmits;
    const requestNodeRemoval = vi.fn();

    const actions = useWorkflowActions({
      canEdit: () => false,
      emit,
      requestNodeRemoval,
      selectNode: vi.fn(),
    });

    actions.handleSaveConfig({
      id: 'step-1',
      name: 'Fetch User',
      config: {},
    });
    actions.handleDeleteStep('step-1');
    actions.handleSave();
    actions.handleRunTest();

    expect(emit).not.toHaveBeenCalled();
    expect(requestNodeRemoval).not.toHaveBeenCalled();
  });
});
