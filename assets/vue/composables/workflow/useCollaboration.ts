import { computed, nextTick, ref, watch } from 'vue';
import type { Node } from '@vue-flow/core';
import { useThrottleFn } from '@vueuse/core';

import { CURSOR_THROTTLE_MS } from '@/constants/layout';
import type { WorkflowNodeData, UserPresence } from '@/types/workflow';
import type { WorkflowEditorEmits } from '@/types/workflowEditor';
import type { useClientStore } from '@/stores/clientStore';

interface UseCollaborationOptions {
  presences: () => UserPresence[];
  currentUserId: () => string | undefined;
  canEdit: () => boolean;
  getSelectedNodes: () => Node<WorkflowNodeData>[];
  getNodes: () => Node<WorkflowNodeData>[];
  setNodes: (nodes: Node<WorkflowNodeData>[]) => void;
  emit: WorkflowEditorEmits;
  store: ReturnType<typeof useClientStore>;
}

export function useCollaboration(options: UseCollaborationOptions) {
  const isUpdatingSelection = ref(false);

  const otherUserPresences = computed(() => {
    return options.presences().filter(p => p.user.id !== options.currentUserId());
  });

  const emitInteraction = useThrottleFn(
    (x: number, y: number, dragging_steps?: Record<string, { x: number; y: number }> | null) => {
      options.emit('mouse_move', { x, y, dragging_steps });
    },
    CURSOR_THROTTLE_MS
  );

  const handleSelectionChange = ({ nodes }: { nodes: Node<WorkflowNodeData>[] }) => {
    if (!options.canEdit()) return;
    const selectedIds = nodes.filter(node => node.type === 'step').map(node => node.id);
    isUpdatingSelection.value = true;
    options.store.selectNode(selectedIds.length === 1 ? selectedIds[0] : null);
    isUpdatingSelection.value = false;
    options.emit('selection_changed', { step_ids: selectedIds });
  };

  watch(
    () => options.getSelectedNodes(),
    newSelection => {
      if (!options.canEdit()) return;
      const selectedIds = newSelection.filter(node => node.type === 'step').map(node => node.id);
      options.emit('selection_changed', { step_ids: selectedIds });
    },
    { deep: true }
  );

  watch(
    () => options.store.selectedNodeId,
    newSelectedId => {
      if (!options.canEdit()) return;
      if (isUpdatingSelection.value) return;

      const nodes = options.getNodes().map(node => ({
        ...node,
        selected: node.id === newSelectedId,
      }));
      options.setNodes(nodes);
    }
  );

  const withSelectionLock = (callback: () => void) => {
    isUpdatingSelection.value = true;
    callback();
    nextTick(() => {
      isUpdatingSelection.value = false;
    });
  };

  return {
    otherUserPresences,
    emitInteraction,
    handleSelectionChange,
    withSelectionLock,
  };
}
