import type { GraphNode } from '@vue-flow/core';

import { DEFAULT_GROUP_DIMENSIONS } from '@/constants/layout';
import type {
  GroupNodeData,
  WorkflowNodeData,
} from '@/shared/ui/workflow-scene/types';
import { getAbsoluteNodePosition, getNodeSize } from '@/lib/workflowGeometry';
import { isGroupNode, isStepNode } from '@/lib/workflowGuards';

import type { DragStartMaps, GroupBounds, NodeDragPointerEvent } from './types';

export const getPointerEvent = (event: NodeDragPointerEvent) => {
  if ('clientX' in event) return event;
  return event.touches[0] ?? event.changedTouches?.[0] ?? null;
};

interface BuildDragStartMapsOptions {
  allNodes: GraphNode<WorkflowNodeData>[];
  eventNodes: GraphNode<WorkflowNodeData>[];
  startGroupByStepId: Map<string, string>;
}

export const buildDragStartMaps = ({
  allNodes,
  eventNodes,
  startGroupByStepId,
}: BuildDragStartMapsOptions): DragStartMaps => {
  const nodeById = new Map(allNodes.map(node => [node.id, node]));
  const startPositions = new Map<string, { x: number; y: number }>();
  const startAbsolutePositions = new Map<string, { x: number; y: number }>();
  const startGroupBounds = new Map<string, GroupBounds>();
  const startStepPositions = new Map<string, { x: number; y: number }>();

  allNodes
    .filter(isGroupNode)
    .forEach(groupNode => {
      const absolute = getAbsoluteNodePosition(groupNode as GraphNode<WorkflowNodeData>);
      const size = getNodeSize(groupNode as GraphNode<WorkflowNodeData>);
      startGroupBounds.set(groupNode.id, {
        x: absolute.x,
        y: absolute.y,
        width: size.width || DEFAULT_GROUP_DIMENSIONS.width,
        height: size.height || DEFAULT_GROUP_DIMENSIONS.height,
      });
    });

  allNodes
    .filter(isStepNode)
    .forEach(stepNode => {
      startStepPositions.set(stepNode.id, { x: stepNode.position.x, y: stepNode.position.y });
    });

  eventNodes.forEach(node => {
    const currentNode = nodeById.get(node.id) ?? node;
    startPositions.set(currentNode.id, { x: currentNode.position.x, y: currentNode.position.y });

    const absolute = getAbsoluteNodePosition(currentNode);
    startAbsolutePositions.set(currentNode.id, { x: absolute.x, y: absolute.y });
  });

  return {
    startPositions,
    startAbsolutePositions,
    startGroupBounds,
    startStepPositions,
    startGroupByStepId,
  };
};

export const getCurrentDraggedNodes = (
  eventNodes: GraphNode<WorkflowNodeData>[],
  allNodes: GraphNode<WorkflowNodeData>[]
) => {
  const nodeById = new Map(allNodes.map(node => [node.id, node]));
  return eventNodes.map(node => nodeById.get(node.id) ?? node);
};

export const boundsChanged = (a: GroupBounds, b: GroupBounds) =>
  a.x !== b.x || a.y !== b.y || a.width !== b.width || a.height !== b.height;

export const positionChanged = (
  prev: { x: number; y: number } | undefined,
  next: { x: number; y: number }
) => {
  if (!prev) return true;
  return prev.x !== next.x || prev.y !== next.y;
};

export const createTxnId = () =>
  `txn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 10)}`;

export const getGroupBoundsForNode = (groupNode: GraphNode<GroupNodeData>) => {
  const position = getAbsoluteNodePosition(groupNode as unknown as GraphNode<WorkflowNodeData>);
  const size = getNodeSize(groupNode as unknown as GraphNode<WorkflowNodeData>);

  return {
    x: position.x,
    y: position.y,
    width: size.width || DEFAULT_GROUP_DIMENSIONS.width,
    height: size.height || DEFAULT_GROUP_DIMENSIONS.height,
  };
};
