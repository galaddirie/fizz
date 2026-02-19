import { nextTick, onMounted, ref, watch } from 'vue';
import type { Edge, Node } from '@vue-flow/core';

import type { EdgeData, WorkflowDraft, WorkflowNodeData } from '@/types/workflow';

interface UseDraftSyncOptions {
  activeDraft: () => WorkflowDraft | undefined;
  nodes: () => Node<WorkflowNodeData>[];
  edges: () => Edge<EdgeData>[];
  setNodes: (nodes: Node<WorkflowNodeData>[]) => void;
  setEdges: (edges: Edge<EdgeData>[]) => void;
  onSyncComplete?: () => void;
}

export function useDraftSync(options: UseDraftSyncOptions) {
  const isMounted = ref(false);
  const isSyncingDraft = ref(false);

  const syncDraftState = async () => {
    if (!isMounted.value) return;
    isSyncingDraft.value = true;
    options.setNodes(options.nodes());
    options.setEdges(options.edges());
    await nextTick();
    options.onSyncComplete?.();
    isSyncingDraft.value = false;
  };

  watch(
    () => [options.activeDraft()?.steps, options.activeDraft()?.connections, options.activeDraft()?.groups],
    () => {
      syncDraftState();
    },
    { deep: true }
  );

  onMounted(() => {
    isMounted.value = true;
    syncDraftState();
  });

  return {
    isMounted,
    isSyncingDraft,
    syncDraftState,
  };
}
