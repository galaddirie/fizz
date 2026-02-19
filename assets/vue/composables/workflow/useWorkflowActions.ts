import type { WorkflowEditorEmits } from '@/types/workflowEditor';

interface UseWorkflowActionsOptions {
  canEdit: () => boolean;
  emit: WorkflowEditorEmits;
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
    options.emit('update_step', {
      step_id: payload.id,
      changes: { name: payload.name, config: payload.config, notes: payload.notes },
    });
  };

  const handleDeleteStep = (stepId: string) => {
    if (!options.canEdit()) return;
    options.requestNodeRemoval(stepId);
  };

  const handleSave = () => {
    if (!options.canEdit()) return;
    options.emit('save_workflow');
  };

  const handleRunTest = () => {
    if (!options.canEdit()) return;
    options.emit('run_test');
  };

  const handleCancelExecution = () => options.emit('cancel_execution');

  const handlePreviewExpression = (payload: {
    step_id: string;
    field_key: string;
    expression: string;
  }) => options.emit('preview_expression', payload);

  const handleToggleWebhookTest = (payload: {
    step_id: string;
    action: 'start' | 'stop';
    path?: string;
    method?: string;
  }) => options.emit('toggle_webhook_test', payload);

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
    handleToggleWebhookTest,
    selectTraceStep,
  };
}
