import type { WorkflowEditorAction, WorkflowEditorViewProps } from '../contracts/workflowEditor';

import { useWorkflowEditorNodeLibrary } from './useWorkflowEditorNodeLibrary';
import { useWorkflowEditorPublish } from './useWorkflowEditorPublish';
import { useWorkflowEditorStatus } from './useWorkflowEditorStatus';

export function useWorkflowEditorChrome(
  props: WorkflowEditorViewProps,
  emitAction: (action: WorkflowEditorAction) => void
) {
  const nodeLibrary = useWorkflowEditorNodeLibrary();
  const publish = useWorkflowEditorPublish(emitAction);
  const status = useWorkflowEditorStatus(props);

  const emitSaveAction = () => emitAction({ type: 'document.save' });
  const emitRevisionOpenAction = () => emitAction({ type: 'revision.open' });

  return {
    ...nodeLibrary,
    ...publish,
    ...status,
    emitSaveAction,
    emitRevisionOpenAction,
  };
}
