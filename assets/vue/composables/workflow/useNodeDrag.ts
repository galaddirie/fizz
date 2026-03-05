import { ref } from 'vue';

import { getAbsoluteNodePosition } from '@/lib/workflowGeometry';
import { workflowTrace } from '@/lib/workflowTrace';
import { isGroupNode, isStepNode } from '@/lib/workflowGuards';

import { constrainPosition, resolveAxisLock } from './node_drag/axisLock';
import { buildCommitDragLayoutPayload } from './node_drag/commit';
import { applyRealtimeGroupAutoFit, collectDraggingGroupBounds } from './node_drag/groupAutoFit';
import { buildDragStartMaps, getCurrentDraggedNodes, getPointerEvent } from './node_drag/session';
import type {
  DragSession,
  NodeDragEvent,
  NodeDragStartEvent,
  NodeDragStopEvent,
  UseNodeDragOptions,
} from './node_drag/types';

export function useNodeDrag(options: UseNodeDragOptions) {
  const dragSession = ref<DragSession | null>(null);

  const createDragSession = (
    nodes: NodeDragStartEvent['nodes'],
    anchorMouse: { x: number; y: number },
    seedInitialSample: boolean
  ): DragSession => {
    const allNodes = options.getNodes();
    const startGroupByStepId = options.groupByStepId();
    const maps = buildDragStartMaps({
      allNodes,
      eventNodes: nodes,
      startGroupByStepId,
    });

    return {
      ...maps,
      lastPositions: new Map(maps.startPositions),
      anchorMouse,
      axisLock: null,
      lockAbsDelta: null,
      recentSamples: seedInitialSample
        ? [{ timestamp: Date.now(), position: anchorMouse }]
        : [],
    };
  };

  const handleNodeDrag = (event: NodeDragEvent) => {
    if (!options.canEdit()) return;
    const pointerEvent = getPointerEvent(event.event);
    if (!pointerEvent) return;
    const flowPosition = options.getFlowPositionFromEvent(pointerEvent);
    if (!flowPosition) return;

    if (!dragSession.value) {
      dragSession.value = createDragSession(event.nodes, flowPosition, false);
    }

    const shiftPressed = 'shiftKey' in event.event ? !!event.event.shiftKey : false;
    const cmdCtrlPressed =
      'metaKey' in event.event ? !!(event.event.metaKey || event.event.ctrlKey) : false;
    const shouldSnap = options.snapEnabled() || cmdCtrlPressed;
    const session = dragSession.value;
    if (!session) return;

    const axisLock = resolveAxisLock(session, shiftPressed, flowPosition);
    const allNodes = options.getNodes();
    const nodeById = new Map(allNodes.map(node => [node.id, node]));
    let draggingStepPositions: Record<string, { x: number; y: number }> = {};

    event.nodes.forEach(node => {
      const currentNode = nodeById.get(node.id) ?? node;
      const startAbsolute = session.startAbsolutePositions.get(node.id);
      if (!startAbsolute) return;

      const constrainedAbsolute = constrainPosition(
        startAbsolute,
        session.anchorMouse,
        flowPosition,
        axisLock,
        shouldSnap,
        Math.max(1, options.gridSize())
      );

      let constrainedPosition = constrainedAbsolute;
      if (isStepNode(currentNode) && currentNode.parentNode) {
        const parentNode = nodeById.get(currentNode.parentNode);
        if (parentNode && isGroupNode(parentNode)) {
          const groupPosition = getAbsoluteNodePosition(parentNode);
          constrainedPosition = {
            x: constrainedAbsolute.x - groupPosition.x,
            y: constrainedAbsolute.y - groupPosition.y,
          };
        }
      }

      if (
        constrainedPosition.x !== currentNode.position.x ||
        constrainedPosition.y !== currentNode.position.y
      ) {
        options.updateNode(node.id, { position: constrainedPosition });
      }
      session.lastPositions.set(node.id, constrainedPosition);

      if (isStepNode(currentNode)) {
        draggingStepPositions[node.id] = constrainedPosition;
      }
    });

    const { stepPositions: nextDraggingStepPositions, groupBoundsById: autofitGroupBounds } =
      applyRealtimeGroupAutoFit({
        draggingStepPositions,
        session,
        currentGroupByStepId: options.groupByStepId(),
        allNodes,
        updateNode: options.updateNode,
      });
    draggingStepPositions = nextDraggingStepPositions;

    const draggingGroupBounds = collectDraggingGroupBounds(event.nodes, nodeById);
    Object.assign(draggingGroupBounds, autofitGroupBounds);

    const hasDraggingSteps = Object.keys(draggingStepPositions).length > 0;
    const hasDraggingGroups = Object.keys(draggingGroupBounds).length > 0;
    options.emitInteraction(
      flowPosition.x,
      flowPosition.y,
      hasDraggingSteps ? draggingStepPositions : null,
      hasDraggingGroups ? draggingGroupBounds : null
    );

    const constrainedDraggedNodes = getCurrentDraggedNodes(event.nodes, options.getNodes());
    const constrainedDraggedStepNodes = constrainedDraggedNodes.filter(isStepNode);
    const ungroupModifierPressed = 'altKey' in event.event ? !!event.event.altKey : false;
    if (ungroupModifierPressed) {
      options.clearGroupingPreview();
    } else {
      options.updateGroupingPreview(constrainedDraggedStepNodes, flowPosition);
    }
  };

  const handleNodeDragStop = (event: NodeDragStopEvent) => {
    if (!options.canEdit()) return;
    const pointerEvent = getPointerEvent(event.event);
    const flowPosition = pointerEvent ? options.getFlowPositionFromEvent(pointerEvent) : null;

    if (flowPosition) {
      options.emitInteraction(flowPosition.x, flowPosition.y, null, null);
    } else {
      options.emitInteraction(undefined, undefined, null, null);
    }
    options.clearGroupingPreview();

    const session = dragSession.value;
    if (!session) return;

    event.nodes.forEach(node => {
      const finalPosition =
        session.lastPositions.get(node.id) ?? session.startPositions.get(node.id) ?? node.position;
      if (finalPosition.x !== node.position.x || finalPosition.y !== node.position.y) {
        options.updateNode(node.id, { position: finalPosition });
      }
    });

    const allNodes = options.getNodes();
    const draggedNodes = getCurrentDraggedNodes(event.nodes, allNodes);
    const ungroupModifierPressed = 'altKey' in event.event ? !!event.event.altKey : false;
    const commitPayload = buildCommitDragLayoutPayload({
      draggedNodes,
      flowPosition,
      ungroupModifierPressed,
      allNodes,
      session,
      currentGroupByStepId: options.groupByStepId(),
      collabSeq: options.getCollabSeq(),
    });

    if (commitPayload) {
      workflowTrace('drop_commit_payload', {
        txn_id: commitPayload.txn_id,
        base_seq: commitPayload.base_seq,
        group_count: commitPayload.groups.length,
        step_position_count: Object.keys(commitPayload.step_positions).length,
        membership_count: Object.keys(commitPayload.group_id_by_step_id).length,
        payload: commitPayload,
      });
      options.dispatch({ type: 'document.layout.commit', payload: commitPayload });
    }

    dragSession.value = null;
  };

  const handleNodeDragStart = (event: NodeDragStartEvent) => {
    if (!options.canEdit()) return;
    const pointerEvent = getPointerEvent(event.event);
    const flowPosition = pointerEvent ? options.getFlowPositionFromEvent(pointerEvent) : null;

    dragSession.value = createDragSession(event.nodes, flowPosition ?? { x: 0, y: 0 }, !!flowPosition);

    workflowTrace('drag_start', {
      dragged_node_ids: event.nodes.map(node => node.id),
      group_count: dragSession.value.startGroupBounds.size,
      step_count: dragSession.value.startStepPositions.size,
      base_seq: options.getCollabSeq(),
    });
  };

  options.onNodeDrag(handleNodeDrag);
  options.onNodeDragStart(handleNodeDragStart);
  options.onNodeDragStop(handleNodeDragStop);
}
