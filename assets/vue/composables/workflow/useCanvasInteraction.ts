import { ref } from 'vue';
import type { GraphNode, XYPosition } from '@vue-flow/core';

import type { WorkflowNodeData } from '@/types/workflow';
import { findGroupAtPoint, getAbsoluteNodePosition } from '@/lib/workflowGeometry';
import { isStepNode } from '@/lib/workflowGuards';

interface UseCanvasInteractionOptions {
  canEdit: () => boolean;
  project: (point: XYPosition) => XYPosition;
  getNodes: () => GraphNode<WorkflowNodeData>[];
  getSelectedNodes: () => GraphNode<WorkflowNodeData>[];
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
  onAddStep: (payload: {
    type_id: string;
    position: { x: number; y: number };
    group_id?: string;
  }) => void;
}

export function useCanvasInteraction(options: UseCanvasInteractionOptions) {
  const canvasRef = ref<HTMLElement | null>(null);

  const getFlowPositionFromEvent = (point: { clientX: number; clientY: number }) => {
    if (!canvasRef.value) return null;

    const { left, top } = canvasRef.value.getBoundingClientRect();
    return options.project({
      x: point.clientX - left,
      y: point.clientY - top,
    });
  };

  const handlePaneMouseMove = (event: MouseEvent) => {
    if (!options.canEdit()) return;
    const flowPosition = getFlowPositionFromEvent(event);
    if (!flowPosition) return;

    if (!options.getSelectedNodes().some(node => node.dragging)) {
      options.emitInteraction(flowPosition.x, flowPosition.y);
    } else {
      const draggingStepNodes = options.getNodes().filter(node => node.dragging).filter(isStepNode);
      options.updateGroupingPreview(draggingStepNodes, flowPosition, event.shiftKey);
    }
  };

  const handleDragOver = (event: DragEvent) => {
    if (!options.canEdit()) return;
    event.preventDefault();
    if (event.dataTransfer) event.dataTransfer.dropEffect = 'move';
  };

  const handleDrop = (event: DragEvent) => {
    if (!options.canEdit()) return;
    const typeId = event.dataTransfer?.getData('application/vueflow');
    if (!typeId) return;

    const position = getFlowPositionFromEvent(event);
    if (position) {
      const targetGroup = findGroupAtPoint(position, options.getNodes());
      if (targetGroup) {
        const groupPosition = getAbsoluteNodePosition(targetGroup);
        options.onAddStep({
          type_id: typeId,
          position: {
            x: position.x - groupPosition.x,
            y: position.y - groupPosition.y,
          },
          group_id: targetGroup.id,
        });
      } else {
        options.onAddStep({ type_id: typeId, position });
      }
    }
  };

  return {
    canvasRef,
    getFlowPositionFromEvent,
    handlePaneMouseMove,
    handleDragOver,
    handleDrop,
  };
}
