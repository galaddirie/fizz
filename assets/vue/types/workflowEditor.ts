import type { XYPosition } from '@vue-flow/core';

import type {
  Workflow,
  Step,
  StepType,
  CredentialOption,
  NodeLibraryItem,
  AddStepAutoConnect,
  Execution,
  StepExecution,
  EditorState,
  UserPresence,
  WorkflowValidationError,
} from '@/types/workflow';

type UndoState = {
  canUndo: boolean;
  canRedo: boolean;
  undoLabel: string | null;
  redoLabel: string | null;
};

export interface WorkflowEditorProps {
  workflow: Workflow;
  stepTypes?: StepType[];
  nodeLibraryItems?: NodeLibraryItem[];
  execution?: Execution | null;
  stepExecutions?: StepExecution[];
  editorState?: EditorState;
  undoState?: UndoState;
  presences?: UserPresence[];
  currentUserId?: string;
  collabSeq?: number;
  saveStatus?: 'saved' | 'saving' | 'error';
  saveError?: string | null;
  expressionPreviews?: Record<string, unknown>;
  credentialOptions?: CredentialOption[];
  debugExecutionId?: string | null;
  validationErrors?: Record<string, WorkflowValidationError[]>;
  widgetToken?: string | null;
}

export type WorkflowEditorCommandType =
  | 'add_step'
  | 'add_group'
  | 'update_group'
  | 'remove_group'
  | 'set_group_membership'
  | 'commit_drag_layout'
  | 'duplicate_steps'
  | 'update_step'
  | 'remove_step'
  | 'move_step'
  | 'move_steps'
  | 'add_connection'
  | 'remove_connection'
  | 'pin_output'
  | 'unpin_output'
  | 'disable_step'
  | 'enable_step'
  | 'run_test'
  | 'run_node'
  | 'submit_credential_bindings'
  | 'cancel_execution'
  | 'undo'
  | 'redo'
  | 'tidy_layout'
  | 'save_workflow'
  | 'validate_draft'
  | 'publish_workflow'
  | 'reauth_connected'
  | 'mouse_move'
  | 'mouse_leave'
  | 'selection_changed'
  | 'preview_expression'
  | 'navigate_revisions';

export interface WorkflowEditorCommand {
  type: WorkflowEditorCommandType;
  payload?: Record<string, unknown>;
}

export type WorkflowEditorLiveEmits = {
  (e: 'editor_command', payload: WorkflowEditorCommand): void;
};

export type WorkflowEditorEmits = {
  (
    e: 'add_step',
    payload: {
      type_id: string;
      position: { x: number; y: number };
      group_id?: string | null;
      auto_connect?: AddStepAutoConnect;
      step_size?: { width: number; height: number };
    }
  ): void;
  (
    e: 'add_group',
    payload: {
      name?: string;
      step_ids: string[];
      color?: string;
      font_size?: number;
      position: { x: number; y: number; width: number; height: number };
      step_positions?: Record<string, XYPosition>;
    }
  ): void;
  (
    e: 'update_group',
    payload: {
      group_id: string;
      changes: {
        name?: string;
        position?: { x?: number; y?: number; width?: number; height?: number };
        collapsed?: boolean;
        color?: string;
        font_size?: number;
      };
    }
  ): void;
  (e: 'remove_group', payload: { group_id: string }): void;
  (
    e: 'set_group_membership',
    payload: {
      group_id?: string | null;
      step_ids: string[];
      step_positions?: Record<string, XYPosition>;
    }
  ): void;
  (
    e: 'commit_drag_layout',
    payload: {
      txn_id: string;
      base_seq?: number;
      groups: Array<{
        group_id: string;
        position: { x: number; y: number; width: number; height: number };
      }>;
      step_positions: Record<string, XYPosition>;
      group_id_by_step_id: Record<string, string | null>;
    }
  ): void;
  (
    e: 'duplicate_steps',
    payload: {
      step_ids: string[];
      position_by_step_id: Record<string, XYPosition>;
      group_id_by_step_id?: Record<string, string>;
    }
  ): void;
  (e: 'update_step', payload: { step_id: string; changes: Partial<Step> }): void;
  (e: 'remove_step', payload: { step_id: string }): void;
  (e: 'move_step', payload: { step_id: string; position: { x: number; y: number } }): void;
  (e: 'move_steps', payload: { step_positions: Record<string, XYPosition> }): void;
  (
    e: 'add_connection',
    payload: {
      source_step_id: string;
      target_step_id: string;
      source_output?: string;
      target_input?: string;
    }
  ): void;
  (e: 'remove_connection', payload: { connection_id: string }): void;
  (
    e: 'pin_output',
    payload: { step_id: string; output_data?: unknown; item_index?: number | null }
  ): void;
  (e: 'unpin_output', payload: { step_id: string }): void;
  (e: 'disable_step', payload: { step_id: string; mode: 'skip' | 'exclude' }): void;
  (e: 'enable_step', payload: { step_id: string }): void;
  (e: 'run_test', payload?: { step_ids?: string[] }): void;
  (e: 'run_node', payload: { step_id: string }): void;
  (
    e: 'submit_credential_bindings',
    payload: {
      target_step_id: string | null;
      bindings: Array<{
        step_id: string;
        requirement_key: string;
        binding_data: Record<string, unknown>;
      }>;
    }
  ): void;
  (e: 'cancel_execution'): void;
  (e: 'undo', payload: { count: number }): void;
  (e: 'redo', payload: { count: number }): void;
  (
    e: 'tidy_layout',
    payload: {
      steps: Array<{ step_id: string; position: { x: number; y: number } }>;
      groups: Array<{ group_id: string; position: { x: number; y: number; width: number; height: number } }>;
      label: string;
    }
  ): void;
  (e: 'save_workflow'): void;
  (e: 'validate_draft'): void;
  (e: 'publish_workflow'): void;
  (e: 'reauth_connected', payload: { target_step_id: string | null }): void;
  (
    e: 'mouse_move',
    payload: {
      x?: number;
      y?: number;
      dragging_steps?: Record<string, XYPosition> | null;
      dragging_groups?: Record<
        string,
        { x: number; y: number; width: number; height: number }
      > | null;
    }
  ): void;
  (e: 'mouse_leave'): void;
  (e: 'selection_changed', payload: { step_ids: string[] }): void;
  (
    e: 'preview_expression',
    payload: { step_id: string; field_key: string; expression: string }
  ): void;
  (e: 'navigate_revisions'): void;
};
