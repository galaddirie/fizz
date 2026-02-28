import { nextTick, onMounted, ref, watch } from 'vue';
import type { Edge, Node } from '@vue-flow/core';

import type { EdgeData, WorkflowDraft, WorkflowNodeData } from '@/types/workflow';

interface UseDraftSyncOptions {
  activeDraft: () => WorkflowDraft | undefined;
  collabSeq?: () => number;
  nodes: () => Node<WorkflowNodeData>[];
  edges: () => Edge<EdgeData>[];
  setNodes: (nodes: Node<WorkflowNodeData>[]) => void;
  setEdges: (edges: Edge<EdgeData>[]) => void;
  onSyncComplete?: () => void;
}

export function useDraftSync(options: UseDraftSyncOptions) {
  const isMounted = ref(false);
  const isSyncingDraft = ref(false);
  const lastSyncKey = ref<string | null>(null);

  const buildSyncKey = () => {
    if (options.collabSeq) {
      return `seq:${options.collabSeq() ?? 0}`;
    }

    const draft = options.activeDraft();
    return [
      draft?.updated_at ?? '',
      draft?.steps?.length ?? 0,
      draft?.connections?.length ?? 0,
      draft?.groups?.length ?? 0,
    ].join(':');
  };

  const syncDraftState = async () => {
    if (!isMounted.value) return;

    const syncKey = buildSyncKey();
    if (lastSyncKey.value === syncKey) return;
    lastSyncKey.value = syncKey;

    isSyncingDraft.value = true;
    options.setNodes(options.nodes());
    options.setEdges(options.edges());
    await nextTick();
    options.onSyncComplete?.();
    isSyncingDraft.value = false;
  };

  watch(
    () => [options.collabSeq?.(), options.activeDraft()?.updated_at],
    () => {
      syncDraftState();
    }
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
