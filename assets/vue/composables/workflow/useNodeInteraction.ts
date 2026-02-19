import { ref } from 'vue';
import type { Ref } from 'vue';
import type { GraphNode, Node, NodeChange, NodeMouseEvent, XYPosition } from '@vue-flow/core';
import type { VueFlow } from '@vue-flow/core';
import type { EventHookOn } from '@vueuse/shared';

import { DOUBLE_CLICK_DELAY_MS } from '@/constants/layout';
import type { StepNodeData, WorkflowNodeData } from '@/types/workflow';
import type { WorkflowEditorEmits } from '@/types/workflowEditor';
import type { useClientStore } from '@/stores/clientStore';
import { isGroupNode, isStepNode } from '@/lib/workflowGuards';

type SelectionContextMenuEvent = { event: MouseEvent; nodes: GraphNode<WorkflowNodeData>[] };

interface UseNodeInteractionOptions {
  canEdit: () => boolean;
  store: ReturnType<typeof useClientStore>;
  nodes: () => Node<WorkflowNodeData>[];
  getNodes: () => GraphNode<WorkflowNodeData>[];
  setNodes: (nodes: Node<WorkflowNodeData>[]) => void;
  applyNodeChanges: (changes: NodeChange[]) => Node<WorkflowNodeData>[];
  removeNodes: (nodeId: string, removeEdges: boolean) => void;
  onNodesChange: EventHookOn<NodeChange[]>;
  project: (point: XYPosition) => XYPosition;
  canvasRef: Ref<HTMLElement | null>;
  vueFlowRef: Ref<InstanceType<typeof VueFlow> | null>;
  emit: WorkflowEditorEmits;
  isSyncingDraft: () => boolean;
}

export function useNodeInteraction(options: UseNodeInteractionOptions) {
  const clickTimer = ref<ReturnType<typeof setTimeout> | null>(null);
  const pendingNodeRemovalIds = new Set<string>();
  const pendingGroupRemovalIds = new Set<string>();

  const findStepNodeById = (nodeId: string) => {
    const node = options.nodes().find(n => n.id === nodeId);
    return node && isStepNode(node) ? node : null;
  };

  const handleNodeClick = (event: NodeMouseEvent) => {
    if (!options.canEdit()) return;
    const node = event.node;

    if (clickTimer.value) {
      clearTimeout(clickTimer.value);
      clickTimer.value = null;
    }

    clickTimer.value = setTimeout(() => {
      if (node.type === 'step') {
        options.store.selectNode(node.id);
      } else {
        options.store.selectNode(null);
      }
      clickTimer.value = null;
    }, DOUBLE_CLICK_DELAY_MS);
  };

  const handleNodeDoubleClick = (event: NodeMouseEvent) => {
    if (!options.canEdit()) return;
    if (clickTimer.value) {
      clearTimeout(clickTimer.value);
      clickTimer.value = null;
    }
    if (event.node.type === 'step') {
      options.store.openConfigModal(event.node.id);
    }
  };

  const findNodeUnderCursor = (event: MouseEvent, nodes: GraphNode<WorkflowNodeData>[]) => {
    const flowElement =
      (options.vueFlowRef.value?.$el as HTMLElement | undefined) ?? options.canvasRef.value;
    if (!flowElement) return null;
    const { left, top } = flowElement.getBoundingClientRect();
    const point = options.project({ x: event.clientX - left, y: event.clientY - top });

    return (
      nodes.find(node => {
        const width = node.dimensions.width;
        const height = node.dimensions.height;
        const position = node.computedPosition ?? node.position;
        return (
          width > 0 &&
          height > 0 &&
          point.x >= position.x &&
          point.x <= position.x + width &&
          point.y >= position.y &&
          point.y <= position.y + height
        );
      }) ?? null
    );
  };

  const handleNodeContextMenu = (event: NodeMouseEvent) => {
    if (!options.canEdit()) return;
    event.event.preventDefault();
    event.event.stopPropagation();
    const mouseEvent = event.event as MouseEvent;
    options.store.showContextMenu(mouseEvent.clientX, mouseEvent.clientY, 'node', event.node.id);
  };

  const handleSelectionContextMenu = ({ event, nodes }: SelectionContextMenuEvent) => {
    if (!options.canEdit()) return;
    event.preventDefault();
    event.stopPropagation();
    const targetNode = findNodeUnderCursor(event, nodes) ?? nodes[0] ?? null;
    options.store.showContextMenu(
      event.clientX,
      event.clientY,
      nodes.length ? 'node' : 'pane',
      targetNode?.id
    );
  };

  const handlePaneContextMenu = (event: MouseEvent) => {
    if (!options.canEdit()) return;
    event.preventDefault();
    options.store.showContextMenu(event.clientX, event.clientY, 'pane');
  };

  const requestNodeRemoval = (nodeId: string) => {
    options.removeNodes(nodeId, true);
  };

  const resetPendingNodeRemovals = () => {
    pendingNodeRemovalIds.clear();
    pendingGroupRemovalIds.clear();
  };

  options.onNodesChange((...changes) => {
    if (options.isSyncingDraft() || !options.canEdit()) return;

    const normalizedChanges = Array.isArray(changes[0])
      ? (changes[0] as NodeChange[])
      : (changes as NodeChange[]);
    const nextChanges: NodeChange[] = [];

    for (const change of normalizedChanges) {
      if (change.type === 'remove') {
        const removedNode = options.getNodes().find(node => node.id === change.id);
        if (removedNode && isGroupNode(removedNode)) {
          if (!pendingGroupRemovalIds.has(change.id)) {
            pendingGroupRemovalIds.add(change.id);
            options.emit('remove_group', { group_id: change.id });
          }
        } else if (!pendingNodeRemovalIds.has(change.id)) {
          pendingNodeRemovalIds.add(change.id);
          options.emit('remove_step', { step_id: change.id });
        }
      }

      nextChanges.push(change);
    }

    const nextNodes = options.applyNodeChanges(nextChanges);
    options.setNodes(nextNodes);
  });

  return {
    handleNodeClick,
    handleNodeDoubleClick,
    handleNodeContextMenu,
    handleSelectionContextMenu,
    handlePaneContextMenu,
    findStepNodeById,
    requestNodeRemoval,
    resetPendingNodeRemovals,
  };
}
