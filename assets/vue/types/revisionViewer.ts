export type UndoEntrySummary = {
  id: string;
  label: string | null;
  timestamp?: string | null;
  depth: number;
};
import type { EditorState, StepType, Workflow, WorkflowDraft } from '@/types/workflow';

export type RevisionKind = 'current' | 'undo' | 'version';

export type RevisionSelection =
  | { kind: 'current'; label: string }
  | { kind: 'undo'; label: string; depth: number }
  | { kind: 'version'; label: string; id: string };

export type RevisionSelectionPayload =
  | { kind: 'current' }
  | { kind: 'undo'; depth: number }
  | { kind: 'version'; id: string };

export interface RevisionViewerProps {
  workflow: Workflow;
  draft: WorkflowDraft;
  revision: RevisionSelection;
  versions: Array<{ id: string; version: number; published_at?: string | null }>;
  undoStack: UndoEntrySummary[];
  stepTypes: StepType[];
  editorState?: EditorState;
}
