import type { UndoEntrySummary } from '@/stores/undoStore';
import type { EditorState, StepType, Workflow, WorkflowDraft } from '@/types/workflow';

export type RevisionKind = 'current' | 'undo' | 'version';

export type RevisionSelection =
  | { kind: 'current'; label: string }
  | { kind: 'undo'; label: string; depth: number }
  | { kind: 'version'; label: string; id: string };

export interface RevisionViewerProps {
  workflow: Workflow;
  draft: WorkflowDraft;
  revision: RevisionSelection;
  versions: Array<{ id: string; version_tag: string; published_at?: string | null }>;
  undoStack: UndoEntrySummary[];
  stepTypes: StepType[];
  editorState?: EditorState;
}

export type RevisionViewerEmits = {
  (e: 'select_revision', payload: { kind: 'current' }): void;
  (e: 'select_revision', payload: { kind: 'undo'; depth: number }): void;
  (e: 'select_revision', payload: { kind: 'version'; id: string }): void;
  (e: 'apply_revision'): void;
  (e: 'navigate_back'): void;
};
