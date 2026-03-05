import { ref } from 'vue';
import { useLiveEvent } from 'live_vue';

import type { WorkflowEditorAction } from '../contracts/workflowEditor';

export function useWorkflowEditorPublish(
  emitAction: (action: WorkflowEditorAction) => void
) {
  const isPublishModalOpen = ref(false);
  const isPublishing = ref(false);
  const publishError = ref<string | null>(null);

  const handlePublish = (payload: { version_tag: string; changelog: string }) => {
    isPublishing.value = true;
    publishError.value = null;
    emitAction({ type: 'document.publish', payload });
  };

  const openPublishModal = () => {
    publishError.value = null;
    isPublishModalOpen.value = true;
  };

  const closePublishModal = () => {
    if (!isPublishing.value) {
      isPublishModalOpen.value = false;
    }
  };

  useLiveEvent<{ success: boolean; error?: string }>('workflow:publish_result', payload => {
    isPublishing.value = false;

    if (payload.success) {
      isPublishModalOpen.value = false;
      return;
    }

    if (payload.error) {
      publishError.value = payload.error;
    }
  });

  return {
    isPublishModalOpen,
    isPublishing,
    publishError,
    openPublishModal,
    closePublishModal,
    handlePublish,
  };
}
