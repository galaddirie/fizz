import type { GraphNode, XYPosition } from '@vue-flow/core';

import { DEFAULT_GROUP_DIMENSIONS } from '@/constants/layout';
import type {
  GroupNodeData,
  WorkflowNodeData,
} from '@/shared/ui/workflow-scene/types';
import {
  GROUP_CONTENT_INSETS,
  buildGroupBoundsFromPositions,
  getAbsoluteNodePosition,
  getNodeSize,
} from '@/lib/workflowGeometry';
import { isGroupNode, isStepNode } from '@/lib/workflowGuards';
import { workflowTrace } from '@/lib/workflowTrace';

import { boundsChanged, getGroupBoundsForNode } from './session';
import type { DragSession, GroupBounds } from './types';

interface ApplyRealtimeGroupAutoFitOptions {
  draggingStepPositions: Record<string, XYPosition>;
  session: DragSession;
  currentGroupByStepId: Map<string, string>;
  allNodes: GraphNode<WorkflowNodeData>[];
  updateNode: (id: string, changes: Partial<GraphNode<WorkflowNodeData>>) => void;
}

const hasGroupBoundsChanged = (groupNode: GraphNode<GroupNodeData>, bounds: GroupBounds) =>
  boundsChanged(getGroupBoundsForNode(groupNode), bounds);

export const applyRealtimeGroupAutoFit = ({
  draggingStepPositions,
  session,
  currentGroupByStepId,
  allNodes,
  updateNode,
}: ApplyRealtimeGroupAutoFitOptions) => {
  const previewGroupBounds: Record<string, GroupBounds> = {};
  const draggedStepIds = Object.keys(draggingStepPositions);
  if (draggedStepIds.length === 0) {
    return { stepPositions: draggingStepPositions, groupBoundsById: previewGroupBounds };
  }

  const affectedGroupIds = new Set<string>();
  draggedStepIds.forEach(stepId => {
    const groupId = currentGroupByStepId.get(stepId);
    if (groupId) affectedGroupIds.add(groupId);
  });
  if (affectedGroupIds.size === 0) {
    return { stepPositions: draggingStepPositions, groupBoundsById: previewGroupBounds };
  }

  const groupNodes = allNodes.filter(isGroupNode) as GraphNode<GroupNodeData>[];
  const stepNodes = allNodes.filter(isStepNode);
  const groupNodesById = new Map(groupNodes.map(node => [node.id, node]));
  const stepNodesById = new Map(stepNodes.map(node => [node.id, node]));

  const relativePositions = new Map<string, XYPosition>();
  stepNodesById.forEach((node, stepId) => {
    relativePositions.set(stepId, { x: node.position.x, y: node.position.y });
  });
  draggedStepIds.forEach(stepId => {
    const position = draggingStepPositions[stepId];
    if (!position) return;
    relativePositions.set(stepId, position);
  });

  const absolutePositions = new Map<string, XYPosition>();
  stepNodesById.forEach((node, stepId) => {
    const relative = relativePositions.get(stepId) ?? node.position;
    const parentGroupId = node.parentNode;

    if (!parentGroupId) {
      absolutePositions.set(stepId, { x: relative.x, y: relative.y });
      return;
    }

    const parentGroup = groupNodesById.get(parentGroupId);
    if (!parentGroup) {
      absolutePositions.set(stepId, { x: relative.x, y: relative.y });
      return;
    }

    const groupPosition = getAbsoluteNodePosition(
      parentGroup as unknown as GraphNode<WorkflowNodeData>
    );
    absolutePositions.set(stepId, {
      x: groupPosition.x + relative.x,
      y: groupPosition.y + relative.y,
    });
  });

  const adjustedDraggingStepPositions = { ...draggingStepPositions };

  affectedGroupIds.forEach(groupId => {
    const groupNode = groupNodesById.get(groupId);
    if (!groupNode) return;

    const groupSteps = stepNodes.filter(stepNode => currentGroupByStepId.get(stepNode.id) === groupId);
    const bounds = buildGroupBoundsFromPositions(
      groupSteps,
      absolutePositions,
      GROUP_CONTENT_INSETS
    );
    if (!bounds) return;
    if (!hasGroupBoundsChanged(groupNode, bounds)) return;

    const previousBounds = session.startGroupBounds.get(groupId) ?? {
      x: groupNode.position.x,
      y: groupNode.position.y,
      width: getNodeSize(groupNode as GraphNode<WorkflowNodeData>).width,
      height: getNodeSize(groupNode as GraphNode<WorkflowNodeData>).height,
    };

    workflowTrace('realtime_autofit_before_after', {
      group_id: groupId,
      before: previousBounds,
      after: bounds,
    });

    updateNode(groupId, {
      position: { x: bounds.x, y: bounds.y },
      style: { width: `${bounds.width}px`, height: `${bounds.height}px` },
    });
    previewGroupBounds[groupId] = bounds;

    groupSteps.forEach(stepNode => {
      const absolute = absolutePositions.get(stepNode.id);
      if (!absolute) return;

      const current = relativePositions.get(stepNode.id) ?? stepNode.position;
      const next = {
        x: absolute.x - bounds.x,
        y: absolute.y - bounds.y,
      };

      if (current.x === next.x && current.y === next.y) return;

      updateNode(stepNode.id, { position: next });
      relativePositions.set(stepNode.id, next);

      if (Object.prototype.hasOwnProperty.call(adjustedDraggingStepPositions, stepNode.id)) {
        adjustedDraggingStepPositions[stepNode.id] = next;
        session.lastPositions.set(stepNode.id, next);
      }
    });
  });

  return { stepPositions: adjustedDraggingStepPositions, groupBoundsById: previewGroupBounds };
};

export const collectDraggingGroupBounds = (
  nodes: GraphNode<WorkflowNodeData>[],
  nodeById: Map<string, GraphNode<WorkflowNodeData>>
) => {
  const draggingGroups: Record<string, GroupBounds> = {};

  nodes.forEach(node => {
    const currentNode = nodeById.get(node.id) ?? node;
    if (!isGroupNode(currentNode)) return;

    const size = getNodeSize(currentNode as GraphNode<WorkflowNodeData>);
    draggingGroups[currentNode.id] = {
      x: currentNode.position.x,
      y: currentNode.position.y,
      width: size.width || DEFAULT_GROUP_DIMENSIONS.width,
      height: size.height || DEFAULT_GROUP_DIMENSIONS.height,
    };
  });

  return draggingGroups;
};
