import type { XYPosition } from '@vue-flow/core';

import type {
  Workflow,
  Step,
  StepType,
  NodeLibraryItem,
  Execution,
  StepExecution,
  EditorState,
  UserPresence,
} from '@/types/workflow';

import { useUndoStore } from '@/stores/undoStore';
type UndoState = ReturnType<typeof useUndoStore>['state'];

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
  expressionPreviews?: Record<string, unknown>;
  debugExecutionId?: string | null;
}

export type WorkflowEditorEmits = {
  (
    e: 'add_step',
    payload: { type_id: string; position: { x: number; y: number }; group_id?: string | null }
  ): void;
  (
    e: 'add_group',
    payload: {
      name?: string;
      step_ids: string[];
      color?: string;
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
        output_step_id?: string;
        color?: string;
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
  (e: 'publish_workflow', payload: { version_tag: string; changelog?: string }): void;
  (
    e: 'mouse_move',
    payload: { x: number; y: number; dragging_steps?: Record<string, XYPosition> | null }
  ): void;
  (e: 'selection_changed', payload: { step_ids: string[] }): void;
  (
    e: 'preview_expression',
    payload: { step_id: string; field_key: string; expression: string }
  ): void;
  (
    e: 'toggle_webhook_test',
    payload: { step_id: string; action: 'start' | 'stop'; path?: string; method?: string }
  ): void;
  (e: 'navigate_revisions'): void;
};
