import { ref } from 'vue';
import type { Ref } from 'vue';
import type { GraphNode, Node, NodeChange, NodeMouseEvent, XYPosition } from '@vue-flow/core';
import type { VueFlow } from '@vue-flow/core';
import type { EventHookOn } from '@vueuse/shared';

import { DEFAULT_GROUP_DIMENSIONS, DOUBLE_CLICK_DELAY_MS } from '@/constants/layout';
import type { StepNodeData, WorkflowNodeData } from '@/types/workflow';
import type { WorkflowEditorEmits } from '@/types/workflowEditor';
import type { useClientStore } from '@/stores/clientStore';
import {
  GROUP_CONTENT_INSETS,
  buildGroupBoundsFromPositions,
  getAbsoluteNodePosition,
  getNodeSize,
} from '@/lib/workflowGeometry';
import { isGroupNode, isStepNode } from '@/lib/workflowGuards';

type SelectionContextMenuEvent = { event: MouseEvent; nodes: GraphNode<WorkflowNodeData>[] };
type GroupBounds = { x: number; y: number; width: number; height: number };

interface UseNodeInteractionOptions {
  canEdit: () => boolean;
  getCollabSeq: () => number;
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
  const createTxnId = () =>
    `txn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 10)}`;

  const boundsChanged = (a: GroupBounds, b: GroupBounds) =>
    a.x !== b.x || a.y !== b.y || a.width !== b.width || a.height !== b.height;

  const positionChanged = (previous: XYPosition, next: XYPosition) =>
    previous.x !== next.x || previous.y !== next.y;

  const computeDeleteLayoutCommit = (removedStepNodes: GraphNode<WorkflowNodeData>[]) => {
    if (removedStepNodes.length === 0) return null;

    const allNodes = options.getNodes();
    const stepNodes = allNodes.filter(isStepNode);
    const groupNodes = allNodes.filter(isGroupNode);
    const removedStepIds = new Set(removedStepNodes.map(node => node.id));
    const affectedGroupIds = new Set<string>();

    removedStepNodes.forEach(stepNode => {
      if (stepNode.parentNode) affectedGroupIds.add(stepNode.parentNode);
    });

    if (affectedGroupIds.size === 0) return null;

    const absolutePositions = new Map<string, XYPosition>();
    stepNodes.forEach(stepNode => {
      if (removedStepIds.has(stepNode.id)) return;
      absolutePositions.set(stepNode.id, getAbsoluteNodePosition(stepNode));
    });

    const nextGroupBoundsById = new Map<string, GroupBounds>();
    affectedGroupIds.forEach(groupId => {
      const remainingSteps = stepNodes.filter(
        stepNode => stepNode.parentNode === groupId && !removedStepIds.has(stepNode.id)
      );
      const bounds = buildGroupBoundsFromPositions(
        remainingSteps,
        absolutePositions,
        GROUP_CONTENT_INSETS
      );

      if (bounds) {
        nextGroupBoundsById.set(groupId, bounds);
      }
    });

    const groupUpdateById = new Map<string, GroupBounds>();
    groupNodes.forEach(groupNode => {
      const groupId = groupNode.id;
      const nextBounds = nextGroupBoundsById.get(groupId);
      if (!nextBounds) return;

      const currentPosition = getAbsoluteNodePosition(groupNode);
      const currentSize = getNodeSize(groupNode);
      const currentBounds: GroupBounds = {
        x: currentPosition.x,
        y: currentPosition.y,
        width: currentSize.width || DEFAULT_GROUP_DIMENSIONS.width,
        height: currentSize.height || DEFAULT_GROUP_DIMENSIONS.height,
      };

      if (!boundsChanged(currentBounds, nextBounds)) return;
      groupUpdateById.set(groupId, nextBounds);
    });

    const stepPositionById = new Map<string, XYPosition>();
    stepNodes.forEach(stepNode => {
      if (removedStepIds.has(stepNode.id)) return;
      if (!stepNode.parentNode) return;

      const nextBounds = nextGroupBoundsById.get(stepNode.parentNode);
      const absolute = absolutePositions.get(stepNode.id);
      if (!nextBounds || !absolute) return;

      const nextPosition = {
        x: absolute.x - nextBounds.x,
        y: absolute.y - nextBounds.y,
      };

      if (!positionChanged(stepNode.position, nextPosition)) return;
      stepPositionById.set(stepNode.id, nextPosition);
    });

    const groups = Array.from(groupUpdateById.entries()).map(([groupId, position]) => ({
      group_id: groupId,
      position,
    }));
    const stepPositions = Array.from(stepPositionById.entries()).reduce<Record<string, XYPosition>>(
      (acc, [stepId, position]) => {
        acc[stepId] = position;
        return acc;
      },
      {}
    );

    const hasChanges = groups.length > 0 || Object.keys(stepPositions).length > 0;
    if (!hasChanges) return null;

    return {
      payload: {
        txn_id: createTxnId(),
        base_seq: options.getCollabSeq(),
        groups,
        step_positions: stepPositions,
        group_id_by_step_id: {},
      },
      groupUpdateById,
      stepPositionById,
    };
  };

  const hasMultiSelectModifier = (event: NodeMouseEvent['event']) => {
    if (!(event instanceof MouseEvent)) return false;
    return event.shiftKey || event.metaKey || event.ctrlKey;
  };

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

    // Let Vue Flow keep additive selection when a multi-select modifier is held.
    if (hasMultiSelectModifier(event.event)) return;

    clickTimer.value = setTimeout(() => {
      if (isStepNode(node)) {
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
    if (isStepNode(event.node)) {
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
    const removedStepNodes: GraphNode<WorkflowNodeData>[] = [];
    const removedStepIds: string[] = [];

    for (const change of normalizedChanges) {
      if (change.type === 'position') {
        // We drive node movement via useNodeDrag/updateNode.
        // Applying Vue Flow's raw position changes here can cause
        // transient incorrect coordinates on multi-node drop.
        continue;
      }

      if (change.type === 'remove') {
        const removedNode = options.getNodes().find(node => node.id === change.id);
        if (removedNode && isGroupNode(removedNode)) {
          if (!pendingGroupRemovalIds.has(change.id)) {
            pendingGroupRemovalIds.add(change.id);
            options.emit('remove_group', { group_id: change.id });
          }
        } else if (!pendingNodeRemovalIds.has(change.id)) {
          if (removedNode && isStepNode(removedNode)) {
            removedStepNodes.push(removedNode);
          }
          pendingNodeRemovalIds.add(change.id);
          removedStepIds.push(change.id);
        }
      }

      nextChanges.push(change);
    }

    const deleteCommit = computeDeleteLayoutCommit(removedStepNodes);
    if (deleteCommit) {
      options.emit('commit_drag_layout', deleteCommit.payload);
    }
    removedStepIds.forEach(stepId => {
      options.emit('remove_step', { step_id: stepId });
    });

    const nextNodes = options.applyNodeChanges(nextChanges);
    if (!deleteCommit) {
      options.setNodes(nextNodes);
      return;
    }

    const adjustedNodes = nextNodes.map(node => {
      if (isGroupNode(node)) {
        const bounds = deleteCommit.groupUpdateById.get(node.id);
        if (!bounds) return node;
        return {
          ...node,
          position: { x: bounds.x, y: bounds.y },
          style: { width: `${bounds.width}px`, height: `${bounds.height}px` },
        };
      }

      if (isStepNode(node)) {
        const position = deleteCommit.stepPositionById.get(node.id);
        if (!position) return node;
        return { ...node, position };
      }

      return node;
    });

    options.setNodes(adjustedNodes);
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
