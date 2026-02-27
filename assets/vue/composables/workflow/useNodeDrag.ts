import { ref } from 'vue';
import type { GraphNode, XYPosition } from '@vue-flow/core';

import { AXIS_LOCK_THRESHOLD, DEFAULT_GROUP_DIMENSIONS } from '@/constants/layout';
import type { GroupNodeData, WorkflowNodeData } from '@/types/workflow';
import type { WorkflowEditorEmits } from '@/types/workflowEditor';
import {
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
  gridSize: () => number;
  snapEnabled: () => boolean;
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
    position: XYPosition | null
  ) => void;
  clearGroupingPreview: () => void;
  getFlowPositionFromEvent: (point: { clientX: number; clientY: number }) => XYPosition | null;
  onNodeDrag: (handler: (event: NodeDragEvent) => void) => void;
  onNodeDragStart: (handler: (event: NodeDragStartEvent) => void) => void;
  onNodeDragStop: (handler: (event: NodeDragStopEvent) => void) => void;
}

type DragAxis = 'x' | 'y';

type PointerSample = {
  timestamp: number;
  position: XYPosition;
};

type DragSession = {
  startPositions: Map<string, XYPosition>;
  lastPositions: Map<string, XYPosition>;
  anchorMouse: XYPosition;
  axisLock: DragAxis | null;
  lockAbsDelta: XYPosition | null;
  recentSamples: PointerSample[];
};

const snapValue = (value: number, grid: number) => grid * Math.round(value / grid);
const INTENT_WINDOW_MS = 110;
const AXIS_ESTABLISH_DEADZONE = AXIS_LOCK_THRESHOLD;
const AXIS_ESTABLISH_RECENT_MIN = 3;
const AXIS_ESTABLISH_RECENT_RATIO = 1.2;
const AXIS_ESTABLISH_OVERALL_RATIO = 1.1;
const AXIS_SWITCH_RECENT_MIN = 3;
const AXIS_SWITCH_RECENT_RATIO = 1.45;
const AXIS_SWITCH_BASE_COUNTER = 8;
const AXIS_SWITCH_COUNTER_SLOPE = 0.12;

const getPointerEvent = (event: MouseEvent | TouchEvent) => {
  if ('clientX' in event) return event;
  return event.touches[0] ?? event.changedTouches?.[0] ?? null;
};

export function useNodeDrag(options: UseNodeDragOptions) {
  const dragSession = ref<DragSession | null>(null);

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

  const getCurrentDraggedNodes = (eventNodes: GraphNode<WorkflowNodeData>[]) => {
    const nodeById = new Map(options.getNodes().map(node => [node.id, node]));
    return eventNodes.map(node => nodeById.get(node.id) ?? node);
  };

  const dominantAxisFromMagnitude = (
    magnitude: XYPosition,
    ratioThreshold: number,
    majorThreshold: number,
    totalThreshold = 0
  ): DragAxis | null => {
    const absX = Math.abs(magnitude.x);
    const absY = Math.abs(magnitude.y);
    if (Math.max(absX, absY) < majorThreshold) return null;
    if (absX + absY < totalThreshold) return null;

    const major = Math.max(absX, absY);
    const minor = Math.min(absX, absY);
    const ratio = major / Math.max(1, minor);
    if (ratio < ratioThreshold) return null;
    return absX >= absY ? 'x' : 'y';
  };

  const toAbsDelta = (from: XYPosition, to: XYPosition): XYPosition => ({
    x: Math.abs(to.x - from.x),
    y: Math.abs(to.y - from.y),
  });

  const trackPointerSample = (session: DragSession, position: XYPosition) => {
    const now = Date.now();
    session.recentSamples.push({ timestamp: now, position });
    const cutoff = now - INTENT_WINDOW_MS;
    while (session.recentSamples.length > 0 && session.recentSamples[0].timestamp < cutoff) {
      session.recentSamples.shift();
    }
  };

  const getRecentDelta = (session: DragSession, currentPosition: XYPosition): XYPosition => {
    const oldest = session.recentSamples[0];
    if (!oldest) {
      return {
        x: currentPosition.x - session.anchorMouse.x,
        y: currentPosition.y - session.anchorMouse.y,
      };
    }

    return {
      x: currentPosition.x - oldest.position.x,
      y: currentPosition.y - oldest.position.y,
    };
  };

  const resolveAxisLock = (session: DragSession, shiftPressed: boolean, flowPosition: XYPosition) => {
    if (!shiftPressed) {
      session.axisLock = null;
      session.lockAbsDelta = null;
      session.recentSamples = [];
      return null;
    }

    trackPointerSample(session, flowPosition);

    const overallAbs = toAbsDelta(session.anchorMouse, flowPosition);
    const recentDelta = getRecentDelta(session, flowPosition);
    const recentAbs = {
      x: Math.abs(recentDelta.x),
      y: Math.abs(recentDelta.y),
    };

    const overallAxis = dominantAxisFromMagnitude(
      overallAbs,
      AXIS_ESTABLISH_OVERALL_RATIO,
      AXIS_LOCK_THRESHOLD,
      AXIS_ESTABLISH_DEADZONE
    );
    const recentAxis = dominantAxisFromMagnitude(
      recentAbs,
      AXIS_ESTABLISH_RECENT_RATIO,
      AXIS_ESTABLISH_RECENT_MIN,
      AXIS_ESTABLISH_RECENT_MIN
    );

    if (!session.axisLock) {
      if (overallAbs.x + overallAbs.y < AXIS_ESTABLISH_DEADZONE) {
        return null;
      }

      const canEstablishFromBoth =
        overallAxis !== null && recentAxis !== null && overallAxis === recentAxis;
      const overallLeadAxis: DragAxis = overallAbs.x >= overallAbs.y ? 'x' : 'y';
      const canEstablishFromRecentOnly =
        recentAxis !== null && overallAxis === null && recentAxis === overallLeadAxis;
      const canEstablishFromOverallOnly =
        overallAxis !== null &&
        recentAxis === null &&
        Math.max(recentAbs.x, recentAbs.y) < AXIS_ESTABLISH_RECENT_MIN;

      if (canEstablishFromBoth || canEstablishFromRecentOnly || canEstablishFromOverallOnly) {
        session.axisLock = (overallAxis ?? recentAxis) as DragAxis;
        session.lockAbsDelta = { ...overallAbs };
      }

      return session.axisLock;
    }

    const currentAxis = session.axisLock;
    const oppositeAxis: DragAxis = currentAxis === 'x' ? 'y' : 'x';
    const recentSwitchAxis = dominantAxisFromMagnitude(
      recentAbs,
      AXIS_SWITCH_RECENT_RATIO,
      AXIS_SWITCH_RECENT_MIN,
      AXIS_SWITCH_RECENT_MIN
    );
    if (recentSwitchAxis !== oppositeAxis) {
      return session.axisLock;
    }

    const lockAbs = session.lockAbsDelta ?? overallAbs;
    const primaryCommit =
      currentAxis === 'x'
        ? Math.max(0, overallAbs.x - lockAbs.x)
        : Math.max(0, overallAbs.y - lockAbs.y);
    const counterMovement =
      currentAxis === 'x'
        ? Math.max(0, overallAbs.y - lockAbs.y)
        : Math.max(0, overallAbs.x - lockAbs.x);
    // Hysteresis: the farther we commit on one axis, the more opposite movement is required to switch.
    const requiredCounterMovement =
      AXIS_SWITCH_BASE_COUNTER + AXIS_SWITCH_COUNTER_SLOPE * primaryCommit;

    if (counterMovement >= requiredCounterMovement) {
      session.axisLock = oppositeAxis;
      session.lockAbsDelta = { ...overallAbs };
    }

    return session.axisLock;
  };

  const constrainPosition = (
    anchorNode: XYPosition,
    anchorMouse: XYPosition,
    mouse: XYPosition,
    axisLock: DragAxis | null,
    shouldSnap: boolean
  ) => {
    const raw = {
      x: anchorNode.x + (mouse.x - anchorMouse.x),
      y: anchorNode.y + (mouse.y - anchorMouse.y),
    };

    const gridSize = Math.max(1, options.gridSize());
    let x = raw.x;
    let y = raw.y;

    if (axisLock === 'x') {
      y = anchorNode.y;
    } else if (axisLock === 'y') {
      x = anchorNode.x;
    }

    if (shouldSnap) {
      if (axisLock === 'x') {
        x = snapValue(x, gridSize);
      } else if (axisLock === 'y') {
        y = snapValue(y, gridSize);
      } else {
        x = snapValue(x, gridSize);
        y = snapValue(y, gridSize);
      }
    }

    return { x, y };
  };

  const handleNodeDrag = (event: NodeDragEvent) => {
    if (!options.canEdit()) return;
    const pointerEvent = getPointerEvent(event.event);
    if (!pointerEvent) return;
    const flowPosition = options.getFlowPositionFromEvent(pointerEvent);
    if (!flowPosition) return;

    if (!dragSession.value) {
      dragSession.value = {
        startPositions: new Map(event.nodes.map(node => [node.id, { ...node.position }])),
        lastPositions: new Map(event.nodes.map(node => [node.id, { ...node.position }])),
        anchorMouse: flowPosition,
        axisLock: null,
        lockAbsDelta: null,
        recentSamples: [],
      };
    }

    const shiftPressed = 'shiftKey' in event.event ? !!event.event.shiftKey : false;
    const cmdCtrlPressed =
      'metaKey' in event.event ? !!(event.event.metaKey || event.event.ctrlKey) : false;
    const shouldSnap = options.snapEnabled() || cmdCtrlPressed;
    const session = dragSession.value;
    if (!session) return;
    const axisLock = resolveAxisLock(session, shiftPressed, flowPosition);

    const draggingStepPositions: Record<string, XYPosition> = {};
    event.nodes.forEach(node => {
      const start = session.startPositions.get(node.id) ?? node.position;
      const constrained = constrainPosition(
        start,
        session.anchorMouse,
        flowPosition,
        axisLock,
        shouldSnap
      );
      if (constrained.x !== node.position.x || constrained.y !== node.position.y) {
        options.updateNode(node.id, { position: constrained });
      }
      session.lastPositions.set(node.id, constrained);

      if (isStepNode(node)) {
        draggingStepPositions[node.id] = constrained;
      }
    });
    const hasDraggingSteps = Object.keys(draggingStepPositions).length > 0;
    options.emitInteraction(
      flowPosition.x,
      flowPosition.y,
      hasDraggingSteps ? draggingStepPositions : null
    );

    const constrainedDraggedNodes = getCurrentDraggedNodes(event.nodes);
    const constrainedDraggedStepNodes = constrainedDraggedNodes.filter(isStepNode);
    options.updateGroupingPreview(constrainedDraggedStepNodes, flowPosition);
  };

  const handleNodeDragStop = (event: NodeDragStopEvent) => {
    if (!options.canEdit()) return;
    options.emitInteraction(0, 0, null);
    options.clearGroupingPreview();

    const session = dragSession.value;
    if (session) {
      event.nodes.forEach(node => {
        const finalPosition =
          session.lastPositions.get(node.id) ?? session.startPositions.get(node.id) ?? node.position;
        if (finalPosition.x !== node.position.x || finalPosition.y !== node.position.y) {
          options.updateNode(node.id, { position: finalPosition });
        }
      });
    }

    const constrainedDraggedNodes = getCurrentDraggedNodes(event.nodes);

    const draggedStepNodes = constrainedDraggedNodes.filter(isStepNode);
    const draggedGroupNodes = constrainedDraggedNodes.filter(isGroupNode);

    draggedGroupNodes.forEach(groupNode => {
      emitGroupPositionUpdate(groupNode as GraphNode<GroupNodeData>);
    });

    let handledStepIds = new Set<string>();
    let targetGroupId: string | null = null;

    if (draggedStepNodes.length > 0) {
      const pointerEvent = getPointerEvent(event.event);

      if (pointerEvent) {
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

    const movedStepPositions: Record<string, XYPosition> = {};
    for (const node of draggedStepNodes) {
      if (handledStepIds.has(node.id)) continue;
      movedStepPositions[node.id] = { x: node.position.x, y: node.position.y };
    }

    const movedStepEntries = Object.entries(movedStepPositions);
    if (movedStepEntries.length === 1) {
      const [stepId, position] = movedStepEntries[0];
      options.emit('move_step', { step_id: stepId, position });
    } else if (movedStepEntries.length > 1) {
      options.emit('move_steps', { step_positions: movedStepPositions });
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

    dragSession.value = null;
  };

  const handleNodeDragStart = (event: NodeDragStartEvent) => {
    if (!options.canEdit()) return;
    const pointerEvent = getPointerEvent(event.event);
    const flowPosition = pointerEvent ? options.getFlowPositionFromEvent(pointerEvent) : null;

    dragSession.value = {
      startPositions: new Map(event.nodes.map(node => [node.id, { ...node.position }])),
      lastPositions: new Map(event.nodes.map(node => [node.id, { ...node.position }])),
      anchorMouse: flowPosition ?? { x: 0, y: 0 },
      axisLock: null,
      lockAbsDelta: null,
      recentSamples: flowPosition
        ? [{ timestamp: Date.now(), position: flowPosition }]
        : [],
    };
  };

  options.onNodeDrag(handleNodeDrag);
  options.onNodeDragStart(handleNodeDragStart);
  options.onNodeDragStop(handleNodeDragStop);
}
