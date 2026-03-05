import { computed, nextTick, ref, watch } from 'vue';
import type { Node } from '@vue-flow/core';
import { useThrottleFn } from '@vueuse/core';

import { CURSOR_THROTTLE_MS } from '@/constants/layout';
import type { WorkflowEditorDispatch } from '@/features/workflow-editor/contracts/workflowEditor';
import { isStepNode } from '@/lib/workflowGuards';
import type { WorkflowNodeData } from '@/shared/ui/workflow-scene/types';
import type { UserPresence } from '@/types/workflow';
import type { useClientStore } from '@/stores/clientStore';

interface UseCollaborationOptions {
  presences: () => UserPresence[];
  currentUserId: () => string | undefined;
  canEdit: () => boolean;
  getNodes: () => Node<WorkflowNodeData>[];
  setNodes: (nodes: Node<WorkflowNodeData>[]) => void;
  dispatch: WorkflowEditorDispatch;
  store: ReturnType<typeof useClientStore>;
}

export function useCollaboration(options: UseCollaborationOptions) {
  const isUpdatingSelection = ref(false);
  const lastSelectionKey = ref('');

  const otherUserPresences = computed(() => {
    return options.presences().filter(p => p.user.id !== options.currentUserId());
  });

  const emitInteraction = useThrottleFn(
    (
      x?: number | null,
      y?: number | null,
      dragging_steps?: Record<string, { x: number; y: number }> | null,
      dragging_groups?: Record<
        string,
        { x: number; y: number; width: number; height: number }
      > | null
    ) => {
      const payload: {
        x?: number;
        y?: number;
        dragging_steps?: Record<string, { x: number; y: number }> | null;
        dragging_groups?: Record<
          string,
          { x: number; y: number; width: number; height: number }
        > | null;
      } = {
        dragging_steps: dragging_steps ?? null,
        dragging_groups: dragging_groups ?? null,
      };

      if (typeof x === 'number' && typeof y === 'number') {
        payload.x = x;
        payload.y = y;
      }

      options.dispatch({ type: 'collaboration.cursor', payload });
    },
    CURSOR_THROTTLE_MS
  );

  const handleSelectionChange = ({ nodes }: { nodes: Node<WorkflowNodeData>[] }) => {
    if (!options.canEdit()) return;
    const selectedIds = nodes.filter(node => isStepNode(node)).map(node => node.id);
    const selectionKey = selectedIds.slice().sort().join(',');

    isUpdatingSelection.value = true;
    options.store.selectNode(selectedIds.length === 1 ? selectedIds[0] : null);
    isUpdatingSelection.value = false;

    if (selectionKey !== lastSelectionKey.value) {
      lastSelectionKey.value = selectionKey;
      options.dispatch({ type: 'collaboration.selection', payload: { step_ids: selectedIds } });
    }
  };

  watch(
    () => options.store.selectedNodeId,
    newSelectedId => {
      if (!options.canEdit()) return;
      if (isUpdatingSelection.value) return;

      // Keep Vue Flow's current selection state (including multi-select) when
      // the store intentionally tracks no single active node.
      if (!newSelectedId) {
        lastSelectionKey.value = '';
        return;
      }

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
