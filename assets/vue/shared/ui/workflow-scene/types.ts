import type { InjectionKey, VNodeRef } from "vue";
import type {
  Connection,
  Edge,
  EdgeTypesObject,
  GraphNode,
  Node,
  NodeMouseEvent,
  NodeTypesObject,
  XYPosition,
} from "@vue-flow/core";

import type {
  StepExecutionStatus,
  StepHandleQuickAddRequest,
  StepKind,
  StepSubnodeSlot,
  NodeRole,
} from "@/types/workflow";

export interface WorkflowStepChanges {
  name?: string;
}

export interface WorkflowGroupChanges {
  name?: string;
  color?: string;
  font_size?: number;
  position?: { x?: number; y?: number; width?: number; height?: number };
}

export interface WorkflowSceneGroupBounds {
  x: number;
  y: number;
  width: number;
  height: number;
}

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
  miniMapNodeColor: (node: GraphNode<WorkflowNodeData>) => string;
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

export interface WorkflowSceneDragLayoutPayload {
  txn_id: string;
  base_seq?: number;
  groups: Array<{
    group_id: string;
    position: WorkflowSceneGroupBounds;
  }>;
  step_positions: WorkflowScenePositionById;
  group_id_by_step_id: Record<string, string | null>;
}

export interface WorkflowSceneStepController {
  run?: (stepId: string) => void;
  update?: (stepId: string, changes: WorkflowStepChanges) => void;
  toggleDisabled?: (stepId: string, isDisabled: boolean) => void;
  togglePin?: (stepId: string, isPinned: boolean) => void;
  quickAdd?: (request: StepHandleQuickAddRequest) => void;
}

export interface WorkflowSceneGroupController {
  update?: (groupId: string, changes: WorkflowGroupChanges) => void;
  commitDragLayout?: (payload: WorkflowSceneDragLayoutPayload) => void;
  emitInteraction?: (
    cursor?: XYPosition | null,
    draggingSteps?: WorkflowScenePositionById | null,
    draggingGroups?: Record<string, WorkflowSceneGroupBounds> | null
  ) => void;
  moveSteps?: (stepPositions: WorkflowScenePositionById) => void;
}

export interface WorkflowSceneController {
  setCanvasRef: VNodeRef;
  setVueFlowRef: VNodeRef;
  handlePaneMouseMove?: (event: MouseEvent) => void;
  handleNodeClick?: (event: NodeMouseEvent) => void;
  handleNodeDoubleClick?: (event: NodeMouseEvent) => void;
  handleNodeContextMenu?: (event: NodeMouseEvent) => void;
  handleSelectionChange?: (event: WorkflowSceneSelectionEvent) => void;
  handleSelectionContextMenu?: (
    event: WorkflowSceneSelectionContextMenuEvent
  ) => void;
  handlePaneContextMenu?: (event: MouseEvent) => void;
  handleEdgeUpdate?: (payload: WorkflowSceneEdgeUpdateEvent) => void;
  handleDragOver?: (event: DragEvent) => void;
  handleDrop?: (event: DragEvent) => void;
  onRunTest?: () => void;
  onCancelExecution?: () => void;
  onToggleSnap?: () => void;
  step?: WorkflowSceneStepController;
  group?: WorkflowSceneGroupController;
}

export type WorkflowScenePositionById = Record<string, XYPosition>;

export const WorkflowSceneControllerKey = Symbol(
  "WorkflowSceneController"
) as InjectionKey<WorkflowSceneController | null>;
