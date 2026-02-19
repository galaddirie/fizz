import { computed, nextTick, onMounted, ref, watch } from 'vue';
import type { LiveHook } from 'live_vue';
import type { Node, XYPosition } from '@vue-flow/core';

import type { WorkflowNodeData } from '@/types/workflow';
import type { WorkflowEditorEmits } from '@/types/workflowEditor';
import type { useClientStore } from '@/stores/clientStore';

const DUPLICATE_OFFSET: XYPosition = { x: 50, y: 50 };

interface UseClipboardOptions {
  getNodes: () => Node<WorkflowNodeData>[];
  getSelectedNodes: () => Node<WorkflowNodeData>[];
  setNodes: (nodes: Node<WorkflowNodeData>[]) => void;
  groupByStepId: () => Map<string, string>;
  store: ReturnType<typeof useClientStore>;
  emit: WorkflowEditorEmits;
  live: LiveHook;
  requestNodeRemoval: (nodeId: string) => void;
  withSelectionLock?: (callback: () => void) => void;
}

export function useClipboard(options: UseClipboardOptions) {
  const clipboard = ref<{ stepIds: string[] } | null>(null);
  const clipboardPasteCount = ref(0);
  const pendingDuplicateSelection = ref<string[] | null>(null);

  const canPaste = computed(() => (clipboard.value?.stepIds.length ?? 0) > 0);

  const resolveActiveNodeIds = (fallbackNodeId?: string | null) => {
    const selectedIds = options
      .getSelectedNodes()
      .filter(node => node.type === 'step')
      .map(node => node.id);
    if (selectedIds.length) return Array.from(new Set(selectedIds));
    if (fallbackNodeId) {
      const fallbackNode = options.getNodes().find(node => node.id === fallbackNodeId);
      if (fallbackNode?.type === 'step') return [fallbackNodeId];
    }
    if (options.store.selectedNodeId) return [options.store.selectedNodeId];
    return [];
  };

  const buildPositionByStepId = (stepIds: string[], offset: XYPosition) => {
    const nodeById = new Map(options.getNodes().map(node => [node.id, node]));
    const positions: Record<string, XYPosition> = {};

    for (const stepId of stepIds) {
      const node = nodeById.get(stepId);
      if (!node) continue;
      positions[stepId] = {
        x: node.position.x + offset.x,
        y: node.position.y + offset.y,
      };
    }

    return positions;
  };

  const buildGroupIdsByStepId = (stepIds: string[]) => {
    const groupIds: Record<string, string> = {};
    const groupByStepId = options.groupByStepId();
    for (const stepId of stepIds) {
      const groupId = groupByStepId.get(stepId);
      if (groupId) {
        groupIds[stepId] = groupId;
      }
    }
    return groupIds;
  };

  const emitDuplicateSteps = (stepIds: string[], offset: XYPosition) => {
    if (!stepIds.length) return;
    const positionByStepId = buildPositionByStepId(stepIds, offset);
    const groupIds = buildGroupIdsByStepId(stepIds);
    options.emit('duplicate_steps', {
      step_ids: stepIds,
      position_by_step_id: positionByStepId,
      group_id_by_step_id: Object.keys(groupIds).length ? groupIds : undefined,
    });
  };

  const handleCopySteps = (stepIds: string[]) => {
    if (!stepIds.length) return;
    clipboard.value = { stepIds };
    clipboardPasteCount.value = 0;
  };

  const handlePasteSteps = () => {
    const stepIds = clipboard.value?.stepIds ?? [];
    if (!stepIds.length) return;
    clipboardPasteCount.value += 1;
    emitDuplicateSteps(stepIds, {
      x: DUPLICATE_OFFSET.x * clipboardPasteCount.value,
      y: DUPLICATE_OFFSET.y * clipboardPasteCount.value,
    });
  };

  const handleDuplicateSteps = (stepIds: string[]) => {
    emitDuplicateSteps(stepIds, DUPLICATE_OFFSET);
  };

  const handleCutSteps = (stepIds: string[]) => {
    if (!stepIds.length) return;
    handleCopySteps(stepIds);
    stepIds.forEach(options.requestNodeRemoval);
  };

  const applyDuplicateSelection = (stepIds: string[]) => {
    if (!stepIds.length) return;
    const idSet = new Set(stepIds);

    const updateSelection = () => {
      options.store.selectNode(stepIds.length === 1 ? stepIds[0] : null);

      const nextNodes = options.getNodes().map(node => ({
        ...node,
        selected: idSet.has(node.id),
      }));

      options.setNodes(nextNodes);
    };

    if (options.withSelectionLock) {
      options.withSelectionLock(updateSelection);
    } else {
      updateSelection();
    }
  };

  const applyPendingDuplicateSelection = () => {
    const pending = pendingDuplicateSelection.value;
    if (!pending || pending.length === 0) return;

    const existingIds = new Set(options.getNodes().map(node => node.id));
    const allAvailable = pending.every(id => existingIds.has(id));
    if (!allAvailable) return;

    pendingDuplicateSelection.value = null;
    applyDuplicateSelection(pending);
  };

  watch(
    () => options.getNodes().map(node => node.id),
    () => {
      applyPendingDuplicateSelection();
    }
  );

  onMounted(() => {
    options.live.handleEvent('duplicate_selection', payload => {
      if (!payload || typeof payload !== 'object') return;
      const data = payload as { step_ids?: string[] };
      if (!Array.isArray(data.step_ids) || data.step_ids.length === 0) return;
      pendingDuplicateSelection.value = data.step_ids;
      nextTick(() => {
        applyPendingDuplicateSelection();
      });
    });
  });

  return {
    clipboard,
    canPaste,
    resolveActiveNodeIds,
    handleCopySteps,
    handlePasteSteps,
    handleDuplicateSteps,
    handleCutSteps,
  };
}
