import { ref } from 'vue';
import type { GraphNode, XYPosition } from '@vue-flow/core';

import { DEFAULT_GROUP_DIMENSIONS } from '@/constants/layout';
import type { GroupNodeData, WorkflowNodeData } from '@/types/workflow';
import type { WorkflowEditorEmits } from '@/types/workflowEditor';
import {
  buildAbsolutePositions,
  buildRelativePositions,
  findGroupAtPoint,
} from '@/lib/workflowGeometry';
import { isGroupNode, isStepNode } from '@/lib/workflowGuards';

type NodeDragEvent = {
  event: MouseEvent | TouchEvent;
  node: GraphNode<WorkflowNodeData>;
  nodes: GraphNode<WorkflowNodeData>[];
};

type NodeDragStartEvent = {
  event: MouseEvent | TouchEvent;
  nodes: GraphNode<WorkflowNodeData>[];
};

type NodeDragStopEvent = {
  event: MouseEvent | TouchEvent;
  nodes: GraphNode<WorkflowNodeData>[];
};

interface UseNodeDragOptions {
  canEdit: () => boolean;
  getNodes: () => GraphNode<WorkflowNodeData>[];
  groupByStepId: () => Map<string, string>;
  updateNode: (id: string, changes: Partial<GraphNode<WorkflowNodeData>>) => void;
  emit: WorkflowEditorEmits;
  emitInteraction: (
    x: number,
    y: number,
    dragging_steps?: Record<string, XYPosition> | null
  ) => void;
  updateGroupingPreview: (
    nodes: GraphNode<WorkflowNodeData>[],
    position: XYPosition | null,
    shiftKey: boolean
  ) => void;
  clearGroupingPreview: () => void;
  getFlowPositionFromEvent: (point: { clientX: number; clientY: number }) => XYPosition | null;
  onNodeDrag: (handler: (event: NodeDragEvent) => void) => void;
  onNodeDragStart: (handler: (event: NodeDragStartEvent) => void) => void;
  onNodeDragStop: (handler: (event: NodeDragStopEvent) => void) => void;
}

export function useNodeDrag(options: UseNodeDragOptions) {
  const ungroupDragStepIds = ref<string[] | null>(null);

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

  const handleNodeDrag = (event: NodeDragEvent) => {
    if (!options.canEdit()) return;
    const mouseEvent = 'clientX' in event.event ? event.event : event.event.touches[0];
    const flowPosition = options.getFlowPositionFromEvent(mouseEvent);
    if (!flowPosition) return;

    const shiftKey = 'shiftKey' in event.event ? event.event.shiftKey : false;
    const draggedStepNodes = event.nodes.filter(isStepNode);

    const dragging_steps: Record<string, XYPosition> = {};
    event.nodes.forEach(node => {
      if (!isStepNode(node)) return;
      dragging_steps[node.id] = node.position;
    });

    const hasDraggingSteps = Object.keys(dragging_steps).length > 0;
    options.emitInteraction(flowPosition.x, flowPosition.y, hasDraggingSteps ? dragging_steps : null);
    options.updateGroupingPreview(draggedStepNodes, flowPosition, shiftKey);
  };

  const restoreExpandParent = () => {
    if (!ungroupDragStepIds.value) return;
    const stepIds = ungroupDragStepIds.value;
    ungroupDragStepIds.value = null;

    stepIds.forEach(stepId => {
      const node = options.getNodes().find(item => item.id === stepId);
      options.updateNode(stepId, { expandParent: node?.parentNode ? true : undefined });
    });
  };

  const handleNodeDragStop = (event: NodeDragStopEvent) => {
    if (!options.canEdit()) return;
    options.emitInteraction(0, 0, null);
    options.clearGroupingPreview();
    restoreExpandParent();

    const draggedStepNodes = event.nodes.filter(isStepNode);
    const draggedGroupNodes = event.nodes.filter(isGroupNode);

    draggedGroupNodes.forEach(groupNode => {
      emitGroupPositionUpdate(groupNode as GraphNode<GroupNodeData>);
    });

    let handledStepIds = new Set<string>();
    let targetGroupId: string | null = null;

    if (draggedStepNodes.length > 0) {
      const pointerEvent =
        'clientX' in event.event
          ? event.event
          : event.event.changedTouches?.[0] ?? event.event.touches?.[0] ?? null;
      const shiftKey = 'shiftKey' in event.event ? event.event.shiftKey : false;

      if (shiftKey) {
        const stepIds = draggedStepNodes.map(node => node.id);
        const hasGroupedSteps = stepIds.some(stepId => options.groupByStepId().has(stepId));

        if (hasGroupedSteps) {
          options.emit('set_group_membership', {
            group_id: null,
            step_ids: stepIds,
            step_positions: buildAbsolutePositions(draggedStepNodes),
          });
          handledStepIds = new Set(stepIds);
        }
      } else if (pointerEvent) {
        const flowPosition = options.getFlowPositionFromEvent(pointerEvent);
        const targetGroup = flowPosition ? findGroupAtPoint(flowPosition, options.getNodes()) : null;

        if (targetGroup) {
          targetGroupId = targetGroup.id;
          const membershipChanged = draggedStepNodes.some(
            node => options.groupByStepId().get(node.id) !== targetGroupId
          );

          if (membershipChanged) {
            const stepIds = draggedStepNodes.map(node => node.id);
            options.emit('set_group_membership', {
              group_id: targetGroupId,
              step_ids: stepIds,
              step_positions: buildRelativePositions(draggedStepNodes, targetGroup),
            });
            handledStepIds = new Set(stepIds);
          }
        }
      }
    }

    for (const node of draggedStepNodes) {
      if (handledStepIds.has(node.id)) continue;
      options.emit('move_step', { step_id: node.id, position: node.position });
    }

    const affectedGroupIds = new Set<string>();
    draggedStepNodes.forEach(node => {
      const groupId = options.groupByStepId().get(node.id);
      if (groupId) affectedGroupIds.add(groupId);
    });
    if (targetGroupId) {
      affectedGroupIds.add(targetGroupId);
    }

    affectedGroupIds.forEach(groupId => {
      const groupNode = options.getNodes().find(node => node.id === groupId);
      if (groupNode && isGroupNode(groupNode)) {
        emitGroupPositionUpdate(groupNode as GraphNode<GroupNodeData>);
      }
    });
  };

  const handleNodeDragStart = (event: NodeDragStartEvent) => {
    if (!options.canEdit()) return;
    const shiftKey = 'shiftKey' in event.event ? event.event.shiftKey : false;
    const draggedStepNodes = event.nodes.filter(isStepNode);
    const hasGroupedSteps = draggedStepNodes.some(node => options.groupByStepId().has(node.id));

    if (shiftKey && hasGroupedSteps) {
      ungroupDragStepIds.value = draggedStepNodes.map(node => node.id);
      draggedStepNodes.forEach(node => {
        options.updateNode(node.id, { expandParent: false });
      });
    } else {
      ungroupDragStepIds.value = null;
    }
  };

  options.onNodeDrag(handleNodeDrag);
  options.onNodeDragStart(handleNodeDragStart);
  options.onNodeDragStop(handleNodeDragStop);
}
