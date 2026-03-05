import type { GraphNode, XYPosition } from '@vue-flow/core';

import type { WorkflowEditorDispatch } from '@/features/workflow-editor/contracts/workflowEditor';
import type { WorkflowNodeData } from '@/shared/ui/workflow-scene/types';

export type NodeDragPointerEvent = MouseEvent | TouchEvent;

export type NodeDragEvent = {
  event: NodeDragPointerEvent;
  node: GraphNode<WorkflowNodeData>;
  nodes: GraphNode<WorkflowNodeData>[];
};

export type NodeDragStartEvent = {
  event: NodeDragPointerEvent;
  nodes: GraphNode<WorkflowNodeData>[];
};

export type NodeDragStopEvent = {
  event: NodeDragPointerEvent;
  nodes: GraphNode<WorkflowNodeData>[];
};

export interface UseNodeDragOptions {
  canEdit: () => boolean;
  gridSize: () => number;
  snapEnabled: () => boolean;
  getCollabSeq: () => number;
  getNodes: () => GraphNode<WorkflowNodeData>[];
  groupByStepId: () => Map<string, string>;
  updateNode: (id: string, changes: Partial<GraphNode<WorkflowNodeData>>) => void;
  dispatch: WorkflowEditorDispatch;
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

export type DragAxis = 'x' | 'y';

export type PointerSample = {
  timestamp: number;
  position: XYPosition;
};

export type GroupBounds = { x: number; y: number; width: number; height: number };

export type CommitDragLayoutPayload = {
  txn_id: string;
  base_seq?: number;
  groups: Array<{ group_id: string; position: GroupBounds }>;
  step_positions: Record<string, XYPosition>;
  group_id_by_step_id: Record<string, string | null>;
};

export type DragSession = {
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

export type DragStartMaps = Pick<
  DragSession,
  | 'startPositions'
  | 'startAbsolutePositions'
  | 'startGroupBounds'
  | 'startStepPositions'
  | 'startGroupByStepId'
>;
