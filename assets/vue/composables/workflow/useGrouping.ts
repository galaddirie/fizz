import { computed, ref } from 'vue';
import type { GraphNode, XYPosition } from '@vue-flow/core';

import { DEFAULT_GROUP_COLOR, DEFAULT_GROUP_DIMENSIONS } from '@/constants/layout';
import type {
  Workflow,
  WorkflowDraft,
  GroupNodeData,
  WorkflowNodeData,
} from '@/types/workflow';
import type { WorkflowEditorEmits } from '@/types/workflowEditor';
import {
  buildAbsolutePositions,
  buildGroupBounds,
  buildRelativePositions,
  findGroupAtPoint,
  findGroupByIntersection,
  getAbsoluteNodePosition,
} from '@/lib/workflowGeometry';
import { isGroupNode, isStepNode } from '@/lib/workflowGuards';

type GroupingPreview = { groupId: string | null; stepIds: string[]; color: string | null };

interface UseGroupingOptions {
  workflow: () => Workflow;
  activeDraft: () => WorkflowDraft | undefined;
  getNodes: () => GraphNode<WorkflowNodeData>[];
  getSelectedNodes: () => GraphNode<WorkflowNodeData>[];
  updateNodeData: (id: string, data: Partial<WorkflowNodeData>) => void;
  emit: WorkflowEditorEmits;
}

export function useGrouping(options: UseGroupingOptions) {
  const groupingPreview = ref<GroupingPreview>({ groupId: null, stepIds: [], color: null });
  const lastGroupingPreview = ref<GroupingPreview>({ groupId: null, stepIds: [], color: null });

  const groupByStepId = computed(() => {
    const map = new Map<string, string>();
    for (const group of options.activeDraft()?.groups || []) {
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
    flowPosition: XYPosition | null,
    shiftKey: boolean
  ) => {
    if (shiftKey || draggedStepNodes.length === 0) {
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
      (options.workflow().draft?.groups || [])
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

    const bounds = buildGroupBounds(selectedNodes);
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
      position: bounds,
      step_positions: stepPositions,
    });
  };

  const ungroupSelectedSteps = () => {
    const selectedNodes = selectedStepNodes.value;
    if (selectedNodes.length === 0) return;

    options.emit('set_group_membership', {
      group_id: null,
      step_ids: selectedNodes.map(node => node.id),
      step_positions: buildAbsolutePositions(selectedNodes),
    });
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
