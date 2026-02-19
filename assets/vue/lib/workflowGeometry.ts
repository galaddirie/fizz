import type { GraphNode, XYPosition } from '@vue-flow/core';

import { DEFAULT_GROUP_DIMENSIONS, DEFAULT_NODE_DIMENSIONS } from '@/constants/layout';
import type { GroupNodeData, StepNodeData, WorkflowNodeData } from '@/types/workflow';
import { isGroupNode, isStepNode } from '@/lib/workflowGuards';

export type NodeRect = { x: number; y: number; width: number; height: number };

export const DEFAULT_GROUP_PADDING = 25;

export const getAbsoluteNodePosition = (node: GraphNode<WorkflowNodeData>) => {
  return node.computedPosition ?? node.position;
};

const parseNodeSize = (value: unknown) => {
  if (typeof value === 'number' && Number.isFinite(value)) return value;
  if (typeof value === 'string') {
    const parsed = parseFloat(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return null;
};

export const getNodeSize = (node: GraphNode<WorkflowNodeData>) => {
  if (node.dimensions.width > 0 && node.dimensions.height > 0) {
    return { width: node.dimensions.width, height: node.dimensions.height };
  }

  const style = typeof node.style === 'function' ? node.style(node) : node.style;
  const styleWidth = parseNodeSize(style?.width);
  const styleHeight = parseNodeSize(style?.height);
  if (styleWidth && styleHeight) {
    return { width: styleWidth, height: styleHeight };
  }

  return node.type === 'group' ? DEFAULT_GROUP_DIMENSIONS : DEFAULT_NODE_DIMENSIONS;
};

export const getNodeRect = (node: GraphNode<WorkflowNodeData>): NodeRect => {
  const position = getAbsoluteNodePosition(node);
  const { width, height } = getNodeSize(node);
  return { x: position.x, y: position.y, width, height };
};

export const getOverlapArea = (rectA: NodeRect, rectB: NodeRect) => {
  const xOverlap = Math.max(
    0,
    Math.min(rectA.x + rectA.width, rectB.x + rectB.width) - Math.max(rectA.x, rectB.x)
  );
  const yOverlap = Math.max(
    0,
    Math.min(rectA.y + rectA.height, rectB.y + rectB.height) - Math.max(rectA.y, rectB.y)
  );
  return xOverlap * yOverlap;
};

export const findGroupAtPoint = (point: XYPosition, nodes: GraphNode<WorkflowNodeData>[]) => {
  const groupNodes = nodes.filter(isGroupNode);
  for (const node of [...groupNodes].reverse()) {
    const { width, height } = getNodeSize(node);
    const position = getAbsoluteNodePosition(node);
    if (
      width > 0 &&
      height > 0 &&
      point.x >= position.x &&
      point.x <= position.x + width &&
      point.y >= position.y &&
      point.y <= position.y + height
    ) {
      return node;
    }
  }
  return null;
};

export const findGroupByIntersection = (
  draggedStepNodes: GraphNode<WorkflowNodeData>[],
  nodes: GraphNode<WorkflowNodeData>[]
) => {
  if (draggedStepNodes.length === 0) return null;

  const groupNodes = nodes.filter(isGroupNode);
  let bestGroup: GraphNode<GroupNodeData> | null = null;
  let bestOverlap = 0;

  groupNodes.forEach(groupNode => {
    const groupRect = getNodeRect(groupNode);
    draggedStepNodes.forEach(stepNode => {
      if (!isStepNode(stepNode)) return;
      const stepRect = getNodeRect(stepNode);
      const overlap = getOverlapArea(stepRect, groupRect);
      if (overlap > bestOverlap) {
        bestOverlap = overlap;
        bestGroup = groupNode as GraphNode<GroupNodeData>;
      }
    });
  });

  return bestOverlap > 0 ? bestGroup : null;
};

export const buildGroupBounds = (
  groupNodes: GraphNode<WorkflowNodeData>[],
  padding = DEFAULT_GROUP_PADDING
) => {
  let minX = Infinity;
  let minY = Infinity;
  let maxX = -Infinity;
  let maxY = -Infinity;

  for (const node of groupNodes) {
    if (!isStepNode(node)) continue;
    const position = getAbsoluteNodePosition(node);
    const width = node.dimensions.width || DEFAULT_NODE_DIMENSIONS.width;
    const height = node.dimensions.height || DEFAULT_NODE_DIMENSIONS.height;

    minX = Math.min(minX, position.x);
    minY = Math.min(minY, position.y);
    maxX = Math.max(maxX, position.x + width);
    maxY = Math.max(maxY, position.y + height);
  }

  if (!isFinite(minX) || !isFinite(minY)) return null;

  const paddedWidth = maxX - minX + padding * 2;
  const paddedHeight = maxY - minY + padding * 2;

  return {
    x: minX - padding,
    y: minY - padding,
    width: Math.max(paddedWidth, DEFAULT_GROUP_DIMENSIONS.width),
    height: Math.max(paddedHeight, DEFAULT_GROUP_DIMENSIONS.height),
  };
};

export const buildGroupBoundsFromPositions = (
  groupNodes: GraphNode<WorkflowNodeData>[],
  positions: Map<string, XYPosition>,
  padding = DEFAULT_GROUP_PADDING
) => {
  let minX = Infinity;
  let minY = Infinity;
  let maxX = -Infinity;
  let maxY = -Infinity;

  for (const node of groupNodes) {
    if (!isStepNode(node)) continue;
    const position = positions.get(node.id) ?? getAbsoluteNodePosition(node);
    const width = node.dimensions.width || DEFAULT_NODE_DIMENSIONS.width;
    const height = node.dimensions.height || DEFAULT_NODE_DIMENSIONS.height;

    minX = Math.min(minX, position.x);
    minY = Math.min(minY, position.y);
    maxX = Math.max(maxX, position.x + width);
    maxY = Math.max(maxY, position.y + height);
  }

  if (!isFinite(minX) || !isFinite(minY)) return null;

  const paddedWidth = maxX - minX + padding * 2;
  const paddedHeight = maxY - minY + padding * 2;

  return {
    x: minX - padding,
    y: minY - padding,
    width: Math.max(paddedWidth, DEFAULT_GROUP_DIMENSIONS.width),
    height: Math.max(paddedHeight, DEFAULT_GROUP_DIMENSIONS.height),
  };
};

export const buildRelativePositions = (
  nodes: GraphNode<WorkflowNodeData>[],
  groupNode: GraphNode<GroupNodeData>
) => {
  const positions: Record<string, XYPosition> = {};
  const groupPosition = getAbsoluteNodePosition(groupNode);

  nodes.forEach(node => {
    if (!isStepNode(node)) return;
    const absolute = getAbsoluteNodePosition(node);
    positions[node.id] = {
      x: absolute.x - groupPosition.x,
      y: absolute.y - groupPosition.y,
    };
  });

  return positions;
};

export const buildAbsolutePositions = (nodes: GraphNode<WorkflowNodeData>[]) => {
  const positions: Record<string, XYPosition> = {};
  nodes.forEach(node => {
    if (!isStepNode(node)) return;
    const absolute = getAbsoluteNodePosition(node);
    positions[node.id] = { x: absolute.x, y: absolute.y };
  });
  return positions;
};
