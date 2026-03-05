import type { GraphNode, XYPosition } from '@vue-flow/core';

import { DEFAULT_GROUP_DIMENSIONS, DEFAULT_NODE_DIMENSIONS } from '@/constants/layout';
import type {
  GroupNodeData,
  StepNodeData,
  WorkflowNodeData,
} from '@/shared/ui/workflow-scene/types';
import { isGroupNode, isStepNode } from '@/lib/workflowGuards';

export type NodeRect = { x: number; y: number; width: number; height: number };

export type GroupContentInsets = {
  left: number;
  right: number;
  top: number;
  bottom: number;
};

const SUBNODE_FALLBACK_DIMENSIONS = { width: 112, height: 96 };

export const GROUP_CONTENT_INSETS: GroupContentInsets = {
  left: 24,
  right: 24,
  top: 64,
  bottom: 52,
};

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

  if (node.type === 'group') return DEFAULT_GROUP_DIMENSIONS;
  if (node.type === 'subnode') return SUBNODE_FALLBACK_DIMENSIONS;
  return DEFAULT_NODE_DIMENSIONS;
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
  insets: GroupContentInsets = GROUP_CONTENT_INSETS
) => {
  let minX = Infinity;
  let minY = Infinity;
  let maxX = -Infinity;
  let maxY = -Infinity;

  for (const node of groupNodes) {
    if (!isStepNode(node)) continue;
    const position = getAbsoluteNodePosition(node);
    const { width, height } = getNodeSize(node);

    minX = Math.min(minX, position.x);
    minY = Math.min(minY, position.y);
    maxX = Math.max(maxX, position.x + width);
    maxY = Math.max(maxY, position.y + height);
  }

  if (!isFinite(minX) || !isFinite(minY)) return null;

  const paddedWidth = maxX - minX + insets.left + insets.right;
  const paddedHeight = maxY - minY + insets.top + insets.bottom;

  return {
    x: minX - insets.left,
    y: minY - insets.top,
    width: Math.max(paddedWidth, DEFAULT_GROUP_DIMENSIONS.width),
    height: Math.max(paddedHeight, DEFAULT_GROUP_DIMENSIONS.height),
  };
};

export const buildGroupBoundsFromPositions = (
  groupNodes: GraphNode<WorkflowNodeData>[],
  positions: Map<string, XYPosition>,
  insets: GroupContentInsets = GROUP_CONTENT_INSETS
) => {
  let minX = Infinity;
  let minY = Infinity;
  let maxX = -Infinity;
  let maxY = -Infinity;

  for (const node of groupNodes) {
    if (!isStepNode(node)) continue;
    const position = positions.get(node.id) ?? getAbsoluteNodePosition(node);
    const { width, height } = getNodeSize(node);

    minX = Math.min(minX, position.x);
    minY = Math.min(minY, position.y);
    maxX = Math.max(maxX, position.x + width);
    maxY = Math.max(maxY, position.y + height);
  }

  if (!isFinite(minX) || !isFinite(minY)) return null;

  const paddedWidth = maxX - minX + insets.left + insets.right;
  const paddedHeight = maxY - minY + insets.top + insets.bottom;

  return {
    x: minX - insets.left,
    y: minY - insets.top,
    width: Math.max(paddedWidth, DEFAULT_GROUP_DIMENSIONS.width),
    height: Math.max(paddedHeight, DEFAULT_GROUP_DIMENSIONS.height),
  };
};

export const resolveGroupContentInsets = (
  bounds: { width: number; height: number },
  insets: GroupContentInsets = GROUP_CONTENT_INSETS
): GroupContentInsets => {
  const safeWidth = Math.max(0, bounds.width);
  const safeHeight = Math.max(0, bounds.height);
  const horizontalTotal = insets.left + insets.right;
  const verticalTotal = insets.top + insets.bottom;

  const horizontalScale =
    horizontalTotal > safeWidth && horizontalTotal > 0
      ? safeWidth / horizontalTotal
      : 1;
  const verticalScale =
    verticalTotal > safeHeight && verticalTotal > 0
      ? safeHeight / verticalTotal
      : 1;

  return {
    left: insets.left * horizontalScale,
    right: insets.right * horizontalScale,
    top: insets.top * verticalScale,
    bottom: insets.bottom * verticalScale,
  };
};

export const getGroupContentRect = (
  bounds: { width: number; height: number },
  insets: GroupContentInsets = GROUP_CONTENT_INSETS
) => {
  const resolvedInsets = resolveGroupContentInsets(bounds, insets);
  const innerLeft = resolvedInsets.left;
  const innerTop = resolvedInsets.top;
  const innerRight = Math.max(innerLeft, bounds.width - resolvedInsets.right);
  const innerBottom = Math.max(innerTop, bounds.height - resolvedInsets.bottom);

  return {
    x: innerLeft,
    y: innerTop,
    width: Math.max(0, innerRight - innerLeft),
    height: Math.max(0, innerBottom - innerTop),
    insets: resolvedInsets,
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
