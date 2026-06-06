import { computed, ref } from 'vue';
import type { GraphNode, XYPosition } from '@vue-flow/core';

import {
  DEFAULT_GROUP_COLOR,
  DEFAULT_GROUP_DIMENSIONS,
  DEFAULT_GROUP_NAME_FONT_SIZE,
} from '@/constants/layout';
import type {
  Workflow,
  WorkflowDraft,
  GroupNodeData,
  WorkflowNodeData,
} from '@/types/workflow';
import type { WorkflowEditorEmits } from '@/types/workflowEditor';
import {
  GROUP_CONTENT_INSETS,
  buildGroupBounds,
  buildGroupBoundsFromPositions,
  findGroupAtPoint,
  findGroupByIntersection,
  getAbsoluteNodePosition,
  getNodeSize,
} from '@/lib/workflowGeometry';
import { isGroupNode, isStepNode } from '@/lib/workflowGuards';

type GroupingPreview = { groupId: string | null; stepIds: string[]; color: string | null };
type GroupBounds = { x: number; y: number; width: number; height: number };

interface UseGroupingOptions {
  workflow: () => Workflow;
  activeDraft: () => WorkflowDraft | undefined;
  getCollabSeq: () => number;
  getNodes: () => GraphNode<WorkflowNodeData>[];
  getSelectedNodes: () => GraphNode<WorkflowNodeData>[];
  updateNodeData: (id: string, data: Partial<WorkflowNodeData>) => void;
  emit: WorkflowEditorEmits;
}

export function useGrouping(options: UseGroupingOptions) {
  const groupingPreview = ref<GroupingPreview>({ groupId: null, stepIds: [], color: null });
  const lastGroupingPreview = ref<GroupingPreview>({ groupId: null, stepIds: [], color: null });
  const createTxnId = () =>
    `txn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 10)}`;

  const boundsChanged = (a: GroupBounds, b: GroupBounds) =>
    a.x !== b.x || a.y !== b.y || a.width !== b.width || a.height !== b.height;

  const positionChanged = (previous: XYPosition | undefined, next: XYPosition) => {
    if (!previous) return true;
    return previous.x !== next.x || previous.y !== next.y;
  };

  const groupByStepId = computed(() => {
    const map = new Map<string, string>();
    for (const group of options.activeDraft()?.step_groups || []) {
      for (const stepId of group.step_ids || []) {
        map.set(stepId, group.id);
      }
    }
    return map;
  });

  const selectedStepNodes = computed(() => options.getSelectedNodes().filter(isStepNode));
  const selectedStepIds = computed(() => selectedStepNodes.value.map(node => node.id));
  const canGroupSelection = computed(() => selectedStepIds.value.length > 0);
  const canUngroupSelection = computed(() =>
    selectedStepIds.value.some(stepId => groupByStepId.value.has(stepId))
  );

  const applyGroupingPreview = (nextPreview: GroupingPreview) => {
    const prevPreview = lastGroupingPreview.value;
    const prevStepIds = new Set(prevPreview.stepIds);
    const nextStepIds = new Set(nextPreview.stepIds);

    if (prevPreview.groupId && prevPreview.groupId !== nextPreview.groupId) {
      options.updateNodeData(prevPreview.groupId, {
        isGroupingTarget: false,
        groupingColor: undefined,
      });
    }
    if (nextPreview.groupId) {
      options.updateNodeData(nextPreview.groupId, {
        isGroupingTarget: true,
        groupingColor: nextPreview.color ?? undefined,
      });
    }

    prevStepIds.forEach(stepId => {
      if (!nextStepIds.has(stepId)) {
        options.updateNodeData(stepId, { isGroupingCandidate: false, groupingColor: undefined });
      }
    });
    nextStepIds.forEach(stepId => {
      if (!prevStepIds.has(stepId) || prevPreview.color !== nextPreview.color) {
        options.updateNodeData(stepId, {
          isGroupingCandidate: true,
          groupingColor: nextPreview.color ?? undefined,
        });
      }
    });

    lastGroupingPreview.value = {
      groupId: nextPreview.groupId,
      stepIds: Array.from(nextStepIds),
      color: nextPreview.color,
    };
  };

  const clearGroupingPreview = () => {
    const nextPreview: GroupingPreview = { groupId: null, stepIds: [], color: null };
    groupingPreview.value = nextPreview;
    applyGroupingPreview(nextPreview);
  };

  const updateGroupingPreview = (
    draggedStepNodes: GraphNode<WorkflowNodeData>[],
    flowPosition: XYPosition | null
  ) => {
    if (draggedStepNodes.length === 0) {
      clearGroupingPreview();
      return;
    }

    const nodes = options.getNodes();
    const targetGroup =
      (flowPosition ? findGroupAtPoint(flowPosition, nodes) : null) ??
      findGroupByIntersection(draggedStepNodes, nodes);
    if (!targetGroup) {
      clearGroupingPreview();
      return;
    }

    const targetGroupId = targetGroup.id;
    const stepIdsToGroup = draggedStepNodes
      .filter(node => groupByStepId.value.get(node.id) !== targetGroupId)
      .map(node => node.id);

    if (stepIdsToGroup.length === 0) {
      clearGroupingPreview();
      return;
    }

    const groupColor = targetGroup.data?.color || DEFAULT_GROUP_COLOR;
    const nextPreview: GroupingPreview = {
      groupId: targetGroupId,
      stepIds: stepIdsToGroup,
      color: groupColor,
    };
    groupingPreview.value = nextPreview;
    applyGroupingPreview(nextPreview);
  };

  const buildGroupName = () => {
    const existingNames = new Set(
      (options.workflow().draft?.step_groups || [])
        .map(group => group.name)
        .filter((name): name is string => !!name)
    );

    if (!existingNames.has('Group')) return 'Group';

    let index = 2;
    let candidate = `Group ${index}`;
    while (existingNames.has(candidate)) {
      index += 1;
      candidate = `Group ${index}`;
    }
    return candidate;
  };

  const createGroupFromSelection = () => {
    const selectedNodes = selectedStepNodes.value;
    if (selectedNodes.length === 0) return;

    const bounds = buildGroupBounds(selectedNodes, GROUP_CONTENT_INSETS);
    if (!bounds) return;

    const stepIds = selectedNodes.map(node => node.id);
    const stepPositions: Record<string, XYPosition> = {};

    selectedNodes.forEach(node => {
      const absolute = getAbsoluteNodePosition(node);
      stepPositions[node.id] = {
        x: absolute.x - bounds.x,
        y: absolute.y - bounds.y,
      };
    });

    options.emit('add_group', {
      name: buildGroupName(),
      step_ids: stepIds,
      color: DEFAULT_GROUP_COLOR,
      font_size: DEFAULT_GROUP_NAME_FONT_SIZE,
      position: bounds,
      step_positions: stepPositions,
    });
  };

  const ungroupSelectedSteps = () => {
    const selectedNodes = selectedStepNodes.value;
    if (selectedNodes.length === 0) return;

    const currentGroupByStepId = groupByStepId.value;
    const membershipOverrides = new Map<string, string | null>();
    selectedNodes.forEach(node => {
      if (currentGroupByStepId.has(node.id)) {
        membershipOverrides.set(node.id, null);
      }
    });

    if (membershipOverrides.size === 0) return;

    const allNodes = options.getNodes();
    const stepNodes = allNodes.filter(isStepNode);
    const stepNodesById = new Map(stepNodes.map(node => [node.id, node]));
    const groupNodes = allNodes.filter(isGroupNode) as GraphNode<GroupNodeData>[];
    const groupNodesById = new Map(groupNodes.map(node => [node.id, node]));
    const absoluteStepPositions = new Map<string, XYPosition>();

    stepNodes.forEach(stepNode => {
      absoluteStepPositions.set(stepNode.id, getAbsoluteNodePosition(stepNode));
    });

    const effectiveGroupIdForStep = (stepId: string) => {
      if (membershipOverrides.has(stepId)) return null;
      return currentGroupByStepId.get(stepId) ?? null;
    };

    const affectedGroupIds = new Set<string>();
    membershipOverrides.forEach((_groupId, stepId) => {
      const groupId = currentGroupByStepId.get(stepId);
      if (groupId) affectedGroupIds.add(groupId);
    });

    const nextGroupBoundsById = new Map<string, GroupBounds>();
    affectedGroupIds.forEach(groupId => {
      const remainingSteps = stepNodes.filter(node => effectiveGroupIdForStep(node.id) === groupId);
      const bounds = buildGroupBoundsFromPositions(
        remainingSteps,
        absoluteStepPositions,
        GROUP_CONTENT_INSETS
      );

      if (bounds) {
        nextGroupBoundsById.set(groupId, bounds);
      }
    });

    const commitGroupUpdates = Array.from(nextGroupBoundsById.entries()).flatMap(
      ([groupId, bounds]) => {
        const currentGroupNode = groupNodesById.get(groupId);
        if (!currentGroupNode) return [];

        const currentSize = getNodeSize(currentGroupNode as GraphNode<WorkflowNodeData>);
        const currentPosition = getAbsoluteNodePosition(
          currentGroupNode as unknown as GraphNode<WorkflowNodeData>
        );
        const currentBounds: GroupBounds = {
          x: currentPosition.x,
          y: currentPosition.y,
          width: currentSize.width || DEFAULT_GROUP_DIMENSIONS.width,
          height: currentSize.height || DEFAULT_GROUP_DIMENSIONS.height,
        };

        if (!boundsChanged(currentBounds, bounds)) return [];

        return [
          {
            group_id: groupId,
            position: bounds,
          },
        ];
      }
    );

    const resolveGroupPosition = (groupId: string) => {
      const nextBounds = nextGroupBoundsById.get(groupId);
      if (nextBounds) {
        return { x: nextBounds.x, y: nextBounds.y };
      }

      const groupNode = groupNodesById.get(groupId);
      if (!groupNode) return null;
      const position = getAbsoluteNodePosition(groupNode as unknown as GraphNode<WorkflowNodeData>);
      return { x: position.x, y: position.y };
    };

    const candidateStepIds = new Set<string>(selectedNodes.map(node => node.id));
    stepNodes.forEach(stepNode => {
      const nextGroupId = effectiveGroupIdForStep(stepNode.id);
      if (nextGroupId && nextGroupBoundsById.has(nextGroupId)) {
        candidateStepIds.add(stepNode.id);
      }
    });

    const commitStepPositions: Record<string, XYPosition> = {};
    candidateStepIds.forEach(stepId => {
      const stepNode = stepNodesById.get(stepId);
      const absolute = absoluteStepPositions.get(stepId);
      if (!stepNode || !absolute) return;

      const nextGroupId = effectiveGroupIdForStep(stepId);
      const nextPosition =
        nextGroupId === null
          ? { x: absolute.x, y: absolute.y }
          : (() => {
              const groupPosition = resolveGroupPosition(nextGroupId);
              if (!groupPosition) return { x: absolute.x, y: absolute.y };

              return {
                x: absolute.x - groupPosition.x,
                y: absolute.y - groupPosition.y,
              };
            })();

      const startGroupId = currentGroupByStepId.get(stepId) ?? null;
      const membershipChanged = startGroupId !== nextGroupId;
      if (membershipChanged || positionChanged(stepNode.position, nextPosition)) {
        commitStepPositions[stepId] = nextPosition;
      }
    });

    const commitMembershipMap: Record<string, string | null> = {};
    membershipOverrides.forEach((_groupId, stepId) => {
      commitMembershipMap[stepId] = null;
    });

    const payload = {
      txn_id: createTxnId(),
      base_seq: options.getCollabSeq(),
      groups: commitGroupUpdates,
      step_positions: commitStepPositions,
      group_id_by_step_id: commitMembershipMap,
    };

    const hasChanges =
      payload.groups.length > 0 ||
      Object.keys(payload.step_positions).length > 0 ||
      Object.keys(payload.group_id_by_step_id).length > 0;

    if (hasChanges) {
      options.emit('commit_drag_layout', payload);
    }
  };

  const removeGroup = (groupId: string) => {
    options.emit('remove_group', { group_id: groupId });
  };

  const emitGroupPositionUpdate = (groupNode: GraphNode<GroupNodeData>) => {
    const width = groupNode.dimensions.width || DEFAULT_GROUP_DIMENSIONS.width;
    const height = groupNode.dimensions.height || DEFAULT_GROUP_DIMENSIONS.height;

    options.emit('update_group', {
      group_id: groupNode.id,
      changes: {
        position: {
          x: groupNode.position.x,
          y: groupNode.position.y,
          width,
          height,
        },
      },
    });
  };

  return {
    groupByStepId,
    groupingPreview,
    canGroupSelection,
    canUngroupSelection,
    selectedStepNodes,
    selectedStepIds,
    clearGroupingPreview,
    updateGroupingPreview,
    createGroupFromSelection,
    ungroupSelectedSteps,
    removeGroup,
    emitGroupPositionUpdate,
  };
}
