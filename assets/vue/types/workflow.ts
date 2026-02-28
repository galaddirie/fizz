import type { Component } from 'vue';

// =============================================================================
// Workflow Types
// =============================================================================

export interface Workflow {
  id: string;
  name: string;
  description?: string;
  status: 'draft' | 'active' | 'archived';
  public: boolean;
  current_version_tag?: string;
  published_version_id?: string;
  user_id: string;
  draft?: WorkflowDraft;
  inserted_at: string;
  updated_at: string;
}

export interface WorkflowDraft {
  id: string;
  workflow_id: string;
  steps: Step[];
  connections: Connection[];
  groups: NodeGroup[];
  triggers: Trigger[];
  settings: Record<string, unknown>;
  inserted_at?: string;
  updated_at?: string;
}

export interface Step {
  id: string;
  type_id: string;
  name: string;
  config: Record<string, unknown>;
  position: { x: number; y: number };
  notes?: string;
}

export interface Connection {
  id: string;
  source_step_id: string;
  source_output: string;
  target_step_id: string;
  target_input: string;
}

export interface NodeGroup {
  id: string;
  name: string;
  step_ids: string[];
  output_step_id: string;
  position: { x?: number; y?: number; width?: number; height?: number };
  color?: string | null;
  font_size?: number | null;
  collapsed: boolean;
}

export interface WorkflowVersion {
  id: string;
  version_tag: string;
  source_hash?: string;
  changelog?: string | null;
  published_at?: string | null;
  published_by?: string | null;
  steps: Step[];
  connections: Connection[];
  groups: NodeGroup[];
}

export interface Trigger {
  id: string;
  type: string;
  config: Record<string, unknown>;
  enabled: boolean;
}

export interface CredentialOption {
  id: string;
  provider: string;
  provider_label: string;
  auth_type: 'api_key' | 'oauth';
  display_name: string;
  owner_user_id: string;
  owner_display_name: string;
  status: string;
  created_at?: string;
  last_used_at?: string;
}

// =============================================================================
// Step Type Registry
// =============================================================================

export type StepKind = 'trigger' | 'action' | 'transform' | 'control_flow';
export type NodeRole = 'root' | 'subnode';

export interface StepSubnodeSlot {
  id: string;
  title?: string;
  description?: string;
  required?: boolean;
  cardinality?: 'one' | 'many';
  accepts?: {
    type_ids?: string[];
  };
  input_key?: string;
}

export interface AddStepAutoConnect {
  source_step_id?: string;
  source_output?: string;
  target_step_id?: string;
  target_input?: string;
}

export type HandleQuickAddFilterMode = 'output' | 'subnode_slot';

export interface StepHandleQuickAddRequest {
  screenPoint: { x: number; y: number };
  autoConnect: AddStepAutoConnect;
  filter: {
    mode: HandleQuickAddFilterMode;
    accepted_type_ids?: string[];
  };
}

export interface StepType {
  id: string;
  name: string;
  description?: string;
  category: string;
  icon?: string;
  step_kind: StepKind;
  node_role?: NodeRole;
  config_schema?: Record<string, unknown>;
  input_schema?: Record<string, unknown>;
  output_schema?: Record<string, unknown>;
  subnode_slots?: StepSubnodeSlot[];
}

export interface NodeLibraryItem {
  type_id: string;
  name: string;
  description: string;
  category: string;
  icon: string;
  step_kind: StepKind;
  node_role?: NodeRole;
}

// =============================================================================
// Vue Flow Node/Edge Data
// =============================================================================

export interface StepNodeData {
  id: string;
  type_id: string;
  name: string;
  config: Record<string, unknown>;
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
  // Fan-out item stats for multi-item steps
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
  onHandleQuickAdd?: (request: StepHandleQuickAddRequest) => void;
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

// =============================================================================
// Execution Types
// =============================================================================

export type ExecutionStatus =
  | 'pending'
  | 'running'
  | 'paused'
  | 'completed'
  | 'failed'
  | 'cancelled'
  | 'timeout';

export type StepExecutionStatus =
  | 'pending'
  | 'queued'
  | 'running'
  | 'completed'
  | 'failed'
  | 'skipped'
  | 'cancelled';

export interface Execution {
  id: string;
  workflow_id: string;
  workflow_version_id?: string;
  status: ExecutionStatus;
  execution_type: 'production' | 'preview' | 'partial';
  trigger: {
    type: string;
    data: Record<string, unknown>;
  };
  context?: Record<string, unknown>;
  output?: Record<string, unknown>;
  error?: {
    type: string;
    message: string;
    details?: Record<string, unknown>;
  };
  metadata?: Record<string, unknown>;
  triggered_by_user_id?: string;
  started_at?: string;
  completed_at?: string;
  inserted_at: string;
  updated_at: string;
}

export interface StepExecution {
  id: string;
  execution_id: string;
  step_id: string;
  step_type_id: string;
  status: StepExecutionStatus;
  input_data?: Record<string, unknown>;
  output_data?: Record<string, unknown>;
  output_item_count?: number;
  // Fan-out item tracking
  // null/undefined = single-item step, 0+ = fan-out item index
  item_index?: number | null;
  // Total items in batch (set on all records in a fan-out)
  items_total?: number | null;
  error?: string;
  attempt: number;
  retry_of_id?: string;
  duration_us?: number;
  queued_at?: string;
  started_at?: string;
  completed_at?: string;
  metadata?: Record<string, unknown>;
  inserted_at: string;
}

export interface TraceEntry {
  id: string;
  step_id: string;
  step_name: string;
  step_type_id?: string;
  status: StepExecutionStatus;
  duration_us?: number;
  timestamp?: string;
  error?: string;
  item_index?: number | null;
  items_total?: number | null;
  isMultiItem?: boolean;
  iterations?: Array<{
    id: string;
    status: StepExecutionStatus;
    duration_us?: number;
    timestamp?: string;
    input_data?: unknown;
    output_data?: unknown;
    error?: string;
    item_index?: number | null;
  }>;
  input_data?: unknown;
  output_data?: unknown;
}

// =============================================================================
// Collaboration Types
// =============================================================================

export interface UserPresence {
  user: {
    id: string;
    name?: string | null;
    email?: string | null;
  };
  cursor?: {
    x: number;
    y: number;
  } | null;
  selected_steps?: string[];
  focused_step?: string | null;
  dragging_steps?: Record<string, { x: number; y: number }> | null;
  dragging_groups?: Record<
    string,
    { x: number; y: number; width: number; height: number }
  > | null;
}

export interface EditorState {
  workflow_id: string;
  pinned_outputs?: Record<string, unknown>;
  disabled_steps?: string[];
  step_locks?: Record<string, string>;
  webhook_test?: WebhookTestState | null;
}

export interface WebhookTestState {
  step_id?: string;
  path: string;
  method?: string;
  enabled_by?: string;
}

// =============================================================================
// Editor UI Types
// =============================================================================

export interface ContextMenuState {
  show: boolean;
  x: number;
  y: number;
  targetNodeId: string | null;
  targetType: 'node' | 'pane';
}

export interface MenuItem {
  id: string;
  label: string;
  icon?: Component;
  shortcut?: string;
  disabled?: boolean;
  danger?: boolean;
  divider?: boolean;
}
