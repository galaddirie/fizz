import type { Component } from 'vue';

// =============================================================================
// Workflow Types
// =============================================================================

export interface WorkflowProjectSummary {
  name?: string | null;
}

export interface Workflow {
  id: string;
  project_id: string;
  name: string;
  description?: string | null;
  created_by_user_id: string;
  archived_at?: string | null;
  latest_version?: number | null;
  published_version_id?: string | null;
  draft?: WorkflowDraft;
  project?: WorkflowProjectSummary;
  inserted_at: string;
  updated_at: string;
}

export type WorkflowDefinitionVersionStatus = 'draft' | 'published' | 'archived';

export interface WorkflowViewport {
  x: number;
  y: number;
  zoom: number;
  [key: string]: unknown;
}

export interface WorkflowDefinitionVersionDraft {
  id: string;
  workflow_definition_id: string;
  version: number;
  status: WorkflowDefinitionVersionStatus;
  steps: Step[];
  connections: Connection[];
  step_groups: StepGroup[];
  viewport: WorkflowViewport;
  settings: Record<string, unknown>;
  compiled_hash?: string | null;
  published_at?: string | null;
  published_by_user_id?: string | null;
  inserted_at?: string;
  updated_at?: string;
}

export type WorkflowDraft = WorkflowDefinitionVersionDraft;

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

export interface StepGroup {
  id: string;
  name: string;
  step_ids: string[];
  position: { x?: number; y?: number; width?: number; height?: number };
  color?: string | null;
  font_size?: number | null;
  collapsed: boolean;
}

export type NodeGroup = StepGroup;

export interface WorkflowDefinitionVersion {
  id: string;
  workflow_definition_id: string;
  version: number;
  status: WorkflowDefinitionVersionStatus;
  compiled_hash?: string | null;
  published_at?: string | null;
  published_by_user_id?: string | null;
  steps: Step[];
  connections: Connection[];
  step_groups: StepGroup[];
  viewport: WorkflowViewport;
  settings: Record<string, unknown>;
  inserted_at?: string;
  updated_at?: string;
}

export type WorkflowVersion = WorkflowDefinitionVersion;

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

export interface StepSubnodeInput {
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

export type HandleQuickAddFilterMode = 'output' | 'subnode_input';

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
  subnode_inputs?: StepSubnodeInput[];
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
  subnode_inputs?: StepSubnodeInput[];
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
  validation_errors?: WorkflowValidationError[];
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

export interface WorkflowRun {
  id: string;
  workflow_definition_id: string;
  workflow_definition_version_id?: string | null;
  project_id?: string | null;
  status: ExecutionStatus;
  trigger: {
    type: string;
    data: Record<string, unknown>;
  };
  triggered_by?: Record<string, unknown> | null;
  input?: Record<string, unknown>;
  output?: Record<string, unknown> | null;
  error?: {
    type: string;
    message: string;
    details?: Record<string, unknown>;
  } | null;
  metadata?: Record<string, unknown>;
  compiled_hash?: string | null;
  triggered_by_user_id?: string;
  started_at?: string | null;
  completed_at?: string | null;
  inserted_at: string;
  updated_at: string;
}

export type Execution = WorkflowRun;

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
}

export interface WorkflowValidationError {
  step_id?: string | null;
  field?: string | null;
  message: string;
  severity: 'error' | 'warning';
  code: string;
}

export interface TriggerImpactEntry {
  step_id: string;
  type_id?: string | null;
  kind: string;
}

export interface TriggerImpact {
  added: TriggerImpactEntry[];
  updated: TriggerImpactEntry[];
  removed: Array<{
    step_id: string;
    kind: string;
  }>;
  unchanged_count: number;
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
