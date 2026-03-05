import type { WorkflowEditorDispatch } from '@/features/workflow-editor/contracts/workflowEditor';

interface UseWorkflowActionsOptions {
  canEdit: () => boolean;
  dispatch: WorkflowEditorDispatch;
  requestNodeRemoval: (stepId: string) => void;
  selectNode: (stepId: string | null) => void;
}

export function useWorkflowActions(options: UseWorkflowActionsOptions) {
  const handleSaveConfig = (payload: {
    id: string;
    name: string;
    config: Record<string, unknown>;
    notes?: string;
  }) => {
    if (!options.canEdit()) return;
    options.dispatch({
      type: 'document.step.update',
      payload: {
        step_id: payload.id,
        changes: { name: payload.name, config: payload.config, notes: payload.notes },
      },
    });
  };

  const handleDeleteStep = (stepId: string) => {
    if (!options.canEdit()) return;
    options.requestNodeRemoval(stepId);
  };

  const handleSave = () => {
    if (!options.canEdit()) return;
    options.dispatch({ type: 'document.save' });
  };

  const handleRunTest = () => {
    if (!options.canEdit()) return;
    options.dispatch({ type: 'execution.runTest' });
  };

  const handleCancelExecution = () => options.dispatch({ type: 'execution.cancel' });

  const handlePreviewExpression = (payload: {
    step_id: string;
    field_key: string;
    expression: string;
  }) => options.dispatch({ type: 'inspector.previewExpression', payload });

  const selectTraceStep = (stepId: string) => {
    options.selectNode(stepId);
  };

  return {
    handleSaveConfig,
    handleDeleteStep,
    handleSave,
    handleRunTest,
    handleCancelExecution,
    handlePreviewExpression,
    selectTraceStep,
  };
}
