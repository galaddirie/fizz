import { ref } from 'vue';
import type { GraphNode, XYPosition } from '@vue-flow/core';

import { AXIS_LOCK_THRESHOLD, DEFAULT_GROUP_DIMENSIONS } from '@/constants/layout';
import type { GroupNodeData, WorkflowNodeData } from '@/types/workflow';
import type { WorkflowEditorEmits } from '@/types/workflowEditor';
import {
  GROUP_CONTENT_INSETS,
  buildGroupBoundsFromPositions,
  findGroupAtPoint,
  getAbsoluteNodePosition,
  getNodeSize,
} from '@/lib/workflowGeometry';
import { workflowTrace } from '@/lib/workflowTrace';
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
  getCollabSeq: () => number;
  getNodes: () => GraphNode<WorkflowNodeData>[];
  groupByStepId: () => Map<string, string>;
  updateNode: (id: string, changes: Partial<GraphNode<WorkflowNodeData>>) => void;
  emit: WorkflowEditorEmits;
  emitInteraction: (
    x?: number | null,
    y?: number | null,
    dragging_steps?: Record<string, XYPosition> | null,
    dragging_groups?: Record<
      string,
      { x: number; y: number; width: number; height: number }
    > | null
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

type GroupBounds = { x: number; y: number; width: number; height: number };

type CommitDragLayoutPayload = {
  txn_id: string;
  base_seq?: number;
  groups: Array<{ group_id: string; position: GroupBounds }>;
  step_positions: Record<string, XYPosition>;
  group_id_by_step_id: Record<string, string | null>;
};

type DragSession = {
  startPositions: Map<string, XYPosition>;
  startAbsolutePositions: Map<string, XYPosition>;
  lastPositions: Map<string, XYPosition>;
  startGroupBounds: Map<string, GroupBounds>;
  startStepPositions: Map<string, XYPosition>;
  startGroupByStepId: Map<string, string>;
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

  const buildDragStartMaps = (eventNodes: GraphNode<WorkflowNodeData>[]) => {
    const nodeById = new Map(options.getNodes().map(node => [node.id, node]));
    const startPositions = new Map<string, XYPosition>();
    const startAbsolutePositions = new Map<string, XYPosition>();
    const startGroupBounds = new Map<string, GroupBounds>();
    const startStepPositions = new Map<string, XYPosition>();
    const startGroupByStepId = options.groupByStepId();

    options
      .getNodes()
      .filter(isGroupNode)
      .forEach(groupNode => {
        const absolute = getAbsoluteNodePosition(groupNode as GraphNode<WorkflowNodeData>);
        const size = getNodeSize(groupNode as GraphNode<WorkflowNodeData>);
        startGroupBounds.set(groupNode.id, {
          x: absolute.x,
          y: absolute.y,
          width: size.width || DEFAULT_GROUP_DIMENSIONS.width,
          height: size.height || DEFAULT_GROUP_DIMENSIONS.height,
        });
      });

    options
      .getNodes()
      .filter(isStepNode)
      .forEach(stepNode => {
        startStepPositions.set(stepNode.id, { x: stepNode.position.x, y: stepNode.position.y });
      });

    eventNodes.forEach(node => {
      const currentNode = nodeById.get(node.id) ?? node;
      startPositions.set(currentNode.id, { x: currentNode.position.x, y: currentNode.position.y });

      const absolute = getAbsoluteNodePosition(currentNode);
      startAbsolutePositions.set(currentNode.id, { x: absolute.x, y: absolute.y });
    });

    return {
      startPositions,
      startAbsolutePositions,
      startGroupBounds,
      startStepPositions,
      startGroupByStepId,
    };
  };

  const getCurrentDraggedNodes = (eventNodes: GraphNode<WorkflowNodeData>[]) => {
    const nodeById = new Map(options.getNodes().map(node => [node.id, node]));
    return eventNodes.map(node => nodeById.get(node.id) ?? node);
  };

  const boundsChanged = (a: GroupBounds, b: GroupBounds) =>
    a.x !== b.x || a.y !== b.y || a.width !== b.width || a.height !== b.height;

  const hasGroupBoundsChanged = (
    groupNode: GraphNode<GroupNodeData>,
    bounds: GroupBounds
  ) => {
    const position = getAbsoluteNodePosition(groupNode as unknown as GraphNode<WorkflowNodeData>);
    const size = getNodeSize(groupNode as unknown as GraphNode<WorkflowNodeData>);

    return boundsChanged(
      {
        x: position.x,
        y: position.y,
        width: size.width || DEFAULT_GROUP_DIMENSIONS.width,
        height: size.height || DEFAULT_GROUP_DIMENSIONS.height,
      },
      bounds
    );
  };

  const positionChanged = (prev: XYPosition | undefined, next: XYPosition) => {
    if (!prev) return true;
    return prev.x !== next.x || prev.y !== next.y;
  };

  const createTxnId = () =>
    `txn_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 10)}`;

  const applyRealtimeGroupAutoFit = (
    draggingStepPositions: Record<string, XYPosition>,
    session: DragSession
  ) => {
    const previewGroupBounds: Record<string, GroupBounds> = {};
    const draggedStepIds = Object.keys(draggingStepPositions);
    if (draggedStepIds.length === 0) {
      return { stepPositions: draggingStepPositions, groupBoundsById: previewGroupBounds };
    }

    const currentGroupByStepId = options.groupByStepId();
    const affectedGroupIds = new Set<string>();
    draggedStepIds.forEach(stepId => {
      const groupId = currentGroupByStepId.get(stepId);
      if (groupId) affectedGroupIds.add(groupId);
    });
    if (affectedGroupIds.size === 0) {
      return { stepPositions: draggingStepPositions, groupBoundsById: previewGroupBounds };
    }

    const allNodes = options.getNodes();
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

      options.updateNode(groupId, {
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

        options.updateNode(stepNode.id, { position: next });
        relativePositions.set(stepNode.id, next);

        if (Object.prototype.hasOwnProperty.call(adjustedDraggingStepPositions, stepNode.id)) {
          adjustedDraggingStepPositions[stepNode.id] = next;
          session.lastPositions.set(stepNode.id, next);
        }
      });
    });

    return { stepPositions: adjustedDraggingStepPositions, groupBoundsById: previewGroupBounds };
  };

  const collectDraggingGroupBounds = (
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
      const {
        startPositions,
        startAbsolutePositions,
        startGroupBounds,
        startStepPositions,
        startGroupByStepId,
      } = buildDragStartMaps(event.nodes);
      dragSession.value = {
        startPositions,
        startAbsolutePositions,
        lastPositions: new Map(startPositions),
        startGroupBounds,
        startStepPositions,
        startGroupByStepId,
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

    const nodeById = new Map(options.getNodes().map(node => [node.id, node]));
    let draggingStepPositions: Record<string, XYPosition> = {};
    event.nodes.forEach(node => {
      const currentNode = nodeById.get(node.id) ?? node;
      const startAbsolute =
        session.startAbsolutePositions.get(node.id) ?? getAbsoluteNodePosition(currentNode);
      const constrainedAbsolute = constrainPosition(
        startAbsolute,
        session.anchorMouse,
        flowPosition,
        axisLock,
        shouldSnap
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
      applyRealtimeGroupAutoFit(draggingStepPositions, session);
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

    const constrainedDraggedNodes = getCurrentDraggedNodes(event.nodes);
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

    const constrainedDraggedNodes = getCurrentDraggedNodes(event.nodes);
    const draggedStepNodes = constrainedDraggedNodes.filter(isStepNode);
    const draggedGroupNodes = constrainedDraggedNodes.filter(isGroupNode) as GraphNode<GroupNodeData>[];

    const currentGroupByStepId = options.groupByStepId();
    const membershipOverrides = new Map<string, string | null>();

    if (draggedStepNodes.length > 0) {
      const ungroupModifierPressed = 'altKey' in event.event ? !!event.event.altKey : false;

      if (ungroupModifierPressed) {
        draggedStepNodes.forEach(node => {
          if (currentGroupByStepId.has(node.id)) {
            membershipOverrides.set(node.id, null);
          }
        });
      } else if (flowPosition) {
        const targetGroup = flowPosition ? findGroupAtPoint(flowPosition, options.getNodes()) : null;

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

    const allNodes = options.getNodes();
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
      const groupSize = getNodeSize(groupNode as GraphNode<WorkflowNodeData>);
      const nextBounds = {
        x: groupNode.position.x,
        y: groupNode.position.y,
        width: groupSize.width || DEFAULT_GROUP_DIMENSIONS.width,
        height: groupSize.height || DEFAULT_GROUP_DIMENSIONS.height,
      };
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
    stepNodeById.forEach((stepNode, stepId) => {
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

    const commitPayload: CommitDragLayoutPayload = {
      txn_id: createTxnId(),
      base_seq: options.getCollabSeq(),
      groups: Array.from(commitGroupBoundsById.entries()).map(([groupId, position]) => ({
        group_id: groupId,
        position,
      })),
      step_positions: commitStepPositions,
      group_id_by_step_id: commitMembershipMap,
    };

    const hasChanges =
      commitPayload.groups.length > 0 ||
      Object.keys(commitPayload.step_positions).length > 0 ||
      Object.keys(commitPayload.group_id_by_step_id).length > 0;

    if (hasChanges) {
      workflowTrace('drop_commit_payload', {
        txn_id: commitPayload.txn_id,
        base_seq: commitPayload.base_seq,
        group_count: commitPayload.groups.length,
        step_position_count: Object.keys(commitPayload.step_positions).length,
        membership_count: Object.keys(commitPayload.group_id_by_step_id).length,
        payload: commitPayload,
      });
      options.emit('commit_drag_layout', commitPayload);
    }

    dragSession.value = null;
  };

  const handleNodeDragStart = (event: NodeDragStartEvent) => {
    if (!options.canEdit()) return;
    const pointerEvent = getPointerEvent(event.event);
    const flowPosition = pointerEvent ? options.getFlowPositionFromEvent(pointerEvent) : null;
    const {
      startPositions,
      startAbsolutePositions,
      startGroupBounds,
      startStepPositions,
      startGroupByStepId,
    } = buildDragStartMaps(event.nodes);

    workflowTrace('drag_start', {
      dragged_node_ids: event.nodes.map(node => node.id),
      group_count: startGroupBounds.size,
      step_count: startStepPositions.size,
      base_seq: options.getCollabSeq(),
    });

    dragSession.value = {
      startPositions,
      startAbsolutePositions,
      lastPositions: new Map(startPositions),
      startGroupBounds,
      startStepPositions,
      startGroupByStepId,
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
