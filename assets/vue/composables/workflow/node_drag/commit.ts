import type { GraphNode, XYPosition } from '@vue-flow/core';

import type {
  GroupNodeData,
  WorkflowNodeData,
} from '@/shared/ui/workflow-scene/types';
import {
  GROUP_CONTENT_INSETS,
  buildGroupBoundsFromPositions,
  findGroupAtPoint,
  getAbsoluteNodePosition,
} from '@/lib/workflowGeometry';
import { isGroupNode, isStepNode } from '@/lib/workflowGuards';

import { boundsChanged, createTxnId, getGroupBoundsForNode, positionChanged } from './session';
import type { CommitDragLayoutPayload, DragSession, GroupBounds } from './types';

interface BuildCommitDragLayoutPayloadOptions {
  draggedNodes: GraphNode<WorkflowNodeData>[];
  flowPosition: XYPosition | null;
  ungroupModifierPressed: boolean;
  allNodes: GraphNode<WorkflowNodeData>[];
  session: DragSession;
  currentGroupByStepId: Map<string, string>;
  collabSeq?: number;
}

export const buildCommitDragLayoutPayload = ({
  draggedNodes,
  flowPosition,
  ungroupModifierPressed,
  allNodes,
  session,
  currentGroupByStepId,
  collabSeq,
}: BuildCommitDragLayoutPayloadOptions): CommitDragLayoutPayload | null => {
  const draggedStepNodes = draggedNodes.filter(isStepNode);
  const draggedGroupNodes = draggedNodes.filter(isGroupNode) as GraphNode<GroupNodeData>[];
  const membershipOverrides = new Map<string, string | null>();

  if (draggedStepNodes.length > 0) {
    if (ungroupModifierPressed) {
      draggedStepNodes.forEach(node => {
        if (currentGroupByStepId.has(node.id)) {
          membershipOverrides.set(node.id, null);
        }
      });
    } else if (flowPosition) {
      const targetGroup = findGroupAtPoint(flowPosition, allNodes);
      if (targetGroup) {
        const targetGroupId = targetGroup.id;
        draggedStepNodes.forEach(node => {
          if (currentGroupByStepId.get(node.id) !== targetGroupId) {
            membershipOverrides.set(node.id, targetGroupId);
          }
        });
      }
    }
  }

  const affectedGroupIds = new Set<string>();
  draggedStepNodes.forEach(node => {
    const groupId = currentGroupByStepId.get(node.id);
    if (groupId) affectedGroupIds.add(groupId);
  });
  membershipOverrides.forEach(groupId => {
    if (groupId) affectedGroupIds.add(groupId);
  });

  const stepNodes = allNodes.filter(isStepNode);
  const groupNodesById = new Map(
    allNodes
      .filter(isGroupNode)
      .map(node => [node.id, node as GraphNode<GroupNodeData>])
  );

  const stepNodeById = new Map(stepNodes.map(node => [node.id, node]));
  draggedStepNodes.forEach(stepNode => {
    stepNodeById.set(stepNode.id, stepNode);
  });

  const absolutePositions = new Map<string, XYPosition>();
  stepNodeById.forEach((node, stepId) => {
    absolutePositions.set(stepId, getAbsoluteNodePosition(node));
  });

  const effectiveGroupIdForStep = (stepId: string) => {
    if (membershipOverrides.has(stepId)) {
      return membershipOverrides.get(stepId) ?? null;
    }
    return currentGroupByStepId.get(stepId) ?? null;
  };

  const groupBoundsById = new Map<string, GroupBounds>();
  affectedGroupIds.forEach(groupId => {
    const groupSteps: GraphNode<WorkflowNodeData>[] = [];
    stepNodeById.forEach(stepNode => {
      if (effectiveGroupIdForStep(stepNode.id) === groupId) {
        groupSteps.push(stepNode);
      }
    });

    const bounds = buildGroupBoundsFromPositions(
      groupSteps,
      absolutePositions,
      GROUP_CONTENT_INSETS
    );
    if (!bounds) return;

    groupBoundsById.set(groupId, bounds);
  });

  const commitGroupBoundsById = new Map<string, GroupBounds>();

  draggedGroupNodes.forEach(groupNode => {
    const nextBounds = getGroupBoundsForNode(groupNode);
    const startBounds = session.startGroupBounds.get(groupNode.id);
    if (!startBounds || boundsChanged(startBounds, nextBounds)) {
      commitGroupBoundsById.set(groupNode.id, nextBounds);
    }
  });

  groupBoundsById.forEach((bounds, groupId) => {
    const startBounds = session.startGroupBounds.get(groupId);
    if (!startBounds || boundsChanged(startBounds, bounds)) {
      commitGroupBoundsById.set(groupId, bounds);
    }
  });

  const resolveTargetGroupPosition = (groupId: string) => {
    const commitBounds = commitGroupBoundsById.get(groupId) ?? groupBoundsById.get(groupId);
    if (commitBounds) return { x: commitBounds.x, y: commitBounds.y };

    const groupNode = groupNodesById.get(groupId);
    if (!groupNode) return null;
    const absolute = getAbsoluteNodePosition(groupNode as GraphNode<WorkflowNodeData>);
    return { x: absolute.x, y: absolute.y };
  };

  const commitStepPositions: Record<string, XYPosition> = {};
  const candidateStepIds = new Set<string>();
  draggedStepNodes.forEach(node => candidateStepIds.add(node.id));
  membershipOverrides.forEach((_groupId, stepId) => candidateStepIds.add(stepId));
  stepNodeById.forEach((_stepNode, stepId) => {
    const groupId = effectiveGroupIdForStep(stepId);
    if (groupId && groupBoundsById.has(groupId)) {
      candidateStepIds.add(stepId);
    }
  });

  candidateStepIds.forEach(stepId => {
    const absolute = absolutePositions.get(stepId);
    if (!absolute) return;

    const nextGroupId = effectiveGroupIdForStep(stepId);
    const nextPosition =
      nextGroupId === null
        ? { x: absolute.x, y: absolute.y }
        : (() => {
            const targetGroupPosition = resolveTargetGroupPosition(nextGroupId);
            if (!targetGroupPosition) return { x: absolute.x, y: absolute.y };
            return {
              x: absolute.x - targetGroupPosition.x,
              y: absolute.y - targetGroupPosition.y,
            };
          })();

    const startPosition = session.startStepPositions.get(stepId);
    const startGroupId = session.startGroupByStepId.get(stepId) ?? null;
    const membershipChanged = startGroupId !== nextGroupId;

    if (membershipChanged || positionChanged(startPosition, nextPosition)) {
      commitStepPositions[stepId] = nextPosition;
    }
  });

  const commitMembershipMap: Record<string, string | null> = {};
  membershipOverrides.forEach((nextGroupId, stepId) => {
    const startGroupId = session.startGroupByStepId.get(stepId) ?? null;
    if (startGroupId !== (nextGroupId ?? null)) {
      commitMembershipMap[stepId] = nextGroupId ?? null;
    }
  });

  const payload: CommitDragLayoutPayload = {
    txn_id: createTxnId(),
    base_seq: collabSeq,
    groups: Array.from(commitGroupBoundsById.entries()).map(([groupId, position]) => ({
      group_id: groupId,
      position,
    })),
    step_positions: commitStepPositions,
    group_id_by_step_id: commitMembershipMap,
  };

  const hasChanges =
    payload.groups.length > 0 ||
    Object.keys(payload.step_positions).length > 0 ||
    Object.keys(payload.group_id_by_step_id).length > 0;

  return hasChanges ? payload : null;
};
