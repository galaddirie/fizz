import { describe, expect, it, vi } from 'vitest';

import type { WorkflowEditorDispatch } from '@/features/workflow-editor/contracts/workflowEditor';
import { useWorkflowActions } from './useWorkflowActions';

describe('useWorkflowActions', () => {
  it('emits workflow updates only when editing is enabled', () => {
    const dispatch = vi.fn() as WorkflowEditorDispatch;
    const requestNodeRemoval = vi.fn();
    const selectNode = vi.fn();

    const actions = useWorkflowActions({
      canEdit: () => true,
      dispatch,
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

    expect(dispatch).toHaveBeenCalledWith({
      type: 'document.step.update',
      payload: {
        step_id: 'step-1',
        changes: {
          name: 'Fetch User',
          config: { method: 'GET' },
          notes: 'Pull the latest profile',
        },
      },
    });
    expect(requestNodeRemoval).toHaveBeenCalledWith('step-1');
    expect(dispatch).toHaveBeenCalledWith({ type: 'document.save' });
    expect(dispatch).toHaveBeenCalledWith({ type: 'execution.runTest' });
    expect(dispatch).toHaveBeenCalledWith({ type: 'execution.cancel' });
    expect(dispatch).toHaveBeenCalledWith({
      type: 'inspector.previewExpression',
      payload: {
        step_id: 'step-1',
        field_key: 'config.url',
        expression: '{{ trigger.url }}',
      },
    });
    expect(selectNode).toHaveBeenCalledWith('step-1');
  });

  it('guards mutating actions when editing is disabled', () => {
    const dispatch = vi.fn() as WorkflowEditorDispatch;
    const requestNodeRemoval = vi.fn();

    const actions = useWorkflowActions({
      canEdit: () => false,
      dispatch,
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

    expect(dispatch).not.toHaveBeenCalled();
    expect(requestNodeRemoval).not.toHaveBeenCalled();
  });
});
