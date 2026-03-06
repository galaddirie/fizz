import type { WorkflowDocumentView } from "@/shared/contracts/workflowDocument";
import type { UndoEntrySummary } from "@/stores/undoStore";
import type { EditorState, StepType, WorkflowDraft } from "@/types/workflow";

export type RevisionKind = "current" | "undo" | "version";

export type RevisionSelection =
  | { kind: "current"; label: string }
  | { kind: "undo"; label: string; depth: number }
  | { kind: "version"; label: string; id: string };

export interface RevisionViewerDocumentSlice {
  workflow: WorkflowDocumentView;
  draft: WorkflowDraft;
  stepTypes: StepType[];
  editorState?: EditorState;
}

export interface RevisionViewerHistorySlice {
  revision: RevisionSelection;
  versions: Array<{
    id: string;
    version_tag: string;
    published_at?: string | null;
  }>;
  undoStack: UndoEntrySummary[];
}

export interface RevisionViewerUiSlice {
  inspectorEnabled?: boolean;
}

export interface RevisionViewerViewProps {
  document: RevisionViewerDocumentSlice;
  history: RevisionViewerHistorySlice;
  ui?: RevisionViewerUiSlice;
}

export type RevisionViewerAction =
  | { type: "history.selectCurrent" }
  | { type: "history.selectUndo"; payload: { depth: number } }
  | { type: "history.selectVersion"; payload: { id: string } }
  | { type: "history.apply" }
  | { type: "navigation.backToEditor" };

export type RevisionViewerDispatch = (action: RevisionViewerAction) => void;

export type RevisionViewerRootEmits = {
  (event: "action", payload: RevisionViewerAction): void;
};
