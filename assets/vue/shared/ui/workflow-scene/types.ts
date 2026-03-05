import type { VNodeRef } from 'vue';
import type {
  Connection,
  Edge,
  EdgeTypesObject,
  GraphNode,
  Node,
  NodeMouseEvent,
  NodeTypesObject,
  XYPosition,
} from '@vue-flow/core';

import type {
  StepExecutionStatus,
  StepKind,
  StepSubnodeSlot,
  UserPresence,
  NodeRole,
} from '@/types/workflow';

export interface StepNodeData {
  id: string;
  type_id: string;
  name: string;
  config: Record<string, unknown>;
  position?: { x: number; y: number };
  notes?: string;
  icon?: string;
  category?: string;
  step_kind?: StepKind;
  node_role?: NodeRole;
  status?: StepExecutionStatus;
  stats?: {
    duration_us?: number;
    bytes?: number;
    out?: number;
  };
  subnode_slots?: StepSubnodeSlot[];
  itemStats?: {
    isMultiItem: boolean;
    itemsTotal: number;
    completed: number;
    failed: number;
    running: number;
  };
  hasInput: boolean;
  hasOutput: boolean;
  disabled?: boolean;
  pinned?: boolean;
  locked_by?: string;
  selected_by?: Array<{
    id: string;
    name: string;
    color: string;
  }>;
  isGroupingCandidate?: boolean;
  groupingColor?: string;
  onRunNode?: (stepId: string) => void;
  onUpdate?: (stepId: string, changes: { name?: string }) => void;
  onToggleDisabled?: (stepId: string, isDisabled: boolean) => void;
  onTogglePin?: (stepId: string, isPinned: boolean) => void;
  onHandleQuickAdd?: (request: {
    screenPoint: { x: number; y: number };
    autoConnect: {
      source_step_id?: string;
      source_output?: string;
      target_step_id?: string;
      target_input?: string;
    };
    filter: {
      mode: 'output' | 'subnode_slot';
      accepted_type_ids?: string[];
    };
  }) => void;
  canEdit?: boolean;
}

export interface EdgeData {
  animated?: boolean;
}

export interface GroupNodeData {
  id: string;
  name: string;
  step_ids: string[];
  collapsed: boolean;
  color?: string;
  font_size?: number;
  isGroupingTarget?: boolean;
  groupingColor?: string;
  collabSeq?: number;
  onUpdate?: (
    groupId: string,
    changes: {
      name?: string;
      color?: string;
      font_size?: number;
      position?: { x?: number; y?: number; width?: number; height?: number };
    }
  ) => void;
  onCommitDragLayout?: (payload: {
    txn_id: string;
    base_seq?: number;
    groups: Array<{ group_id: string; position: { x: number; y: number; width: number; height: number } }>;
    step_positions: Record<string, { x: number; y: number }>;
    group_id_by_step_id: Record<string, string | null>;
  }) => void;
  onEmitInteraction?: (
    cursor?: { x: number; y: number } | null,
    dragging_steps?: Record<string, { x: number; y: number }> | null,
    dragging_groups?: Record<
      string,
      { x: number; y: number; width: number; height: number }
    > | null
  ) => void;
  onMoveSteps?: (stepPositions: Record<string, { x: number; y: number }>) => void;
  canEdit?: boolean;
}

export type WorkflowNodeData = StepNodeData | GroupNodeData;

export interface WorkflowSceneModel {
  nodes: Node<WorkflowNodeData>[];
  edges: Edge<EdgeData>[];
  nodeTypes: NodeTypesObject;
  edgeTypes: EdgeTypesObject;
  snapEnabled: boolean;
  gridSize: number;
  effectiveSnapToGrid: boolean;
  canEdit: boolean;
  isPreviewActive: boolean;
  previewLabel: string;
  isMounted: boolean;
  otherUserPresences: UserPresence[];
  currentUserId?: string;
  viewport: { x: number; y: number; zoom: number };
  miniMapNodeColor: (node: GraphNode<WorkflowNodeData>) => string;
  isExecutionFailed: boolean;
  isExecutionRunning: boolean;
  workflowExecutionsLink?: string | null;
}

export interface WorkflowSceneSelectionEvent {
  nodes: GraphNode<WorkflowNodeData>[];
}

export interface WorkflowSceneSelectionContextMenuEvent {
  event: MouseEvent;
  nodes: GraphNode<WorkflowNodeData>[];
}

export interface WorkflowSceneEdgeUpdateEvent {
  edge: Edge<EdgeData>;
  connection: Connection;
}

export interface WorkflowSceneController {
  setCanvasRef: VNodeRef;
  setVueFlowRef: VNodeRef;
  handlePaneMouseMove?: (event: MouseEvent) => void;
  handleNodeClick?: (event: NodeMouseEvent) => void;
  handleNodeDoubleClick?: (event: NodeMouseEvent) => void;
  handleNodeContextMenu?: (event: NodeMouseEvent) => void;
  handleSelectionChange?: (event: WorkflowSceneSelectionEvent) => void;
  handleSelectionContextMenu?: (event: WorkflowSceneSelectionContextMenuEvent) => void;
  handlePaneContextMenu?: (event: MouseEvent) => void;
  handleEdgeUpdate?: (payload: WorkflowSceneEdgeUpdateEvent) => void;
  handleDragOver?: (event: DragEvent) => void;
  handleDrop?: (event: DragEvent) => void;
  onRunTest?: () => void;
  onCancelExecution?: () => void;
  onToggleSnap?: () => void;
}

export type WorkflowScenePositionById = Record<string, XYPosition>;

