import type { XYPosition } from "@vue-flow/core";

import type { WorkflowDocumentView } from "@/shared/contracts/workflowDocument";
import type { UndoState } from "@/stores/undoStore";
import type {
  AddStepAutoConnect,
  CredentialOption,
  EditorState,
  Execution,
  NodeLibraryItem,
  Step,
  StepExecution,
  StepType,
  UserPresence,
} from "@/types/workflow";

export interface WorkflowEditorDocumentSlice {
  workflow: WorkflowDocumentView;
  editorState?: EditorState;
  expressionPreviews: Record<string, unknown>;
  undoState?: UndoState;
}

export interface WorkflowEditorCatalogSlice {
  stepTypes: StepType[];
  nodeLibraryItems: NodeLibraryItem[];
  credentialOptions: CredentialOption[];
}

export interface WorkflowEditorExecutionSlice {
  execution: Execution | null;
  stepExecutions: StepExecution[];
  debugExecutionId?: string | null;
}

export interface WorkflowEditorCollaborationSlice {
  presences: UserPresence[];
  currentUserId?: string;
  collabSeq: number;
}

export interface WorkflowEditorUiSlice {
  revisionPreviewLabel?: string | null;
}

export interface WorkflowEditorViewProps {
  document: WorkflowEditorDocumentSlice;
  catalog: WorkflowEditorCatalogSlice;
  execution: WorkflowEditorExecutionSlice;
  collaboration: WorkflowEditorCollaborationSlice;
  ui?: WorkflowEditorUiSlice;
}

export type WorkflowEditorAction =
  | {
      type: "document.step.add";
      payload: {
        type_id: string;
        position: { x: number; y: number };
        group_id?: string | null;
        auto_connect?: AddStepAutoConnect;
        step_size?: { width: number; height: number };
      };
    }
  | {
      type: "document.group.add";
      payload: {
        name?: string;
        step_ids: string[];
        color?: string;
        font_size?: number;
        position: { x: number; y: number; width: number; height: number };
        step_positions?: Record<string, XYPosition>;
      };
    }
  | {
      type: "document.group.update";
      payload: {
        group_id: string;
        changes: {
          name?: string;
          position?: {
            x?: number;
            y?: number;
            width?: number;
            height?: number;
          };
          collapsed?: boolean;
          output_step_id?: string;
          color?: string;
          font_size?: number;
        };
      };
    }
  | { type: "document.group.remove"; payload: { group_id: string } }
  | {
      type: "document.group.membership.set";
      payload: {
        group_id?: string | null;
        step_ids: string[];
        step_positions?: Record<string, XYPosition>;
      };
    }
  | {
      type: "document.layout.commit";
      payload: {
        txn_id: string;
        base_seq?: number;
        groups: Array<{
          group_id: string;
          position: { x: number; y: number; width: number; height: number };
        }>;
        step_positions: Record<string, XYPosition>;
        group_id_by_step_id: Record<string, string | null>;
      };
    }
  | {
      type: "document.step.duplicate";
      payload: {
        step_ids: string[];
        position_by_step_id: Record<string, XYPosition>;
        group_id_by_step_id?: Record<string, string>;
      };
    }
  | {
      type: "document.step.update";
      payload: { step_id: string; changes: Partial<Step> };
    }
  | { type: "document.step.remove"; payload: { step_id: string } }
  | {
      type: "document.step.move";
      payload: { step_id: string; position: { x: number; y: number } };
    }
  | {
      type: "document.step.moveMany";
      payload: { step_positions: Record<string, XYPosition> };
    }
  | {
      type: "document.connection.add";
      payload: {
        source_step_id: string;
        target_step_id: string;
        source_output?: string;
        target_input?: string;
      };
    }
  | { type: "document.connection.remove"; payload: { connection_id: string } }
  | {
      type: "document.output.pin";
      payload: {
        step_id: string;
        output_data?: unknown;
        item_index?: number | null;
      };
    }
  | { type: "document.output.unpin"; payload: { step_id: string } }
  | {
      type: "document.step.disable";
      payload: { step_id: string; mode: "skip" | "exclude" };
    }
  | { type: "document.step.enable"; payload: { step_id: string } }
  | { type: "document.undo"; payload: { count: number } }
  | { type: "document.redo"; payload: { count: number } }
  | {
      type: "document.layout.tidy";
      payload: {
        steps: Array<{ step_id: string; position: { x: number; y: number } }>;
        groups: Array<{
          group_id: string;
          position: { x: number; y: number; width: number; height: number };
        }>;
        label: string;
      };
    }
  | { type: "document.save" }
  | {
      type: "document.publish";
      payload: { version_tag: string; changelog?: string };
    }
  | {
      type: "collaboration.cursor";
      payload: {
        x?: number;
        y?: number;
        dragging_steps?: Record<string, XYPosition> | null;
        dragging_groups?: Record<
          string,
          { x: number; y: number; width: number; height: number }
        > | null;
      };
    }
  | { type: "collaboration.selection"; payload: { step_ids: string[] } }
  | {
      type: "inspector.previewExpression";
      payload: { step_id: string; field_key: string; expression: string };
    }
  | { type: "execution.runTest"; payload?: { step_ids?: string[] } }
  | { type: "execution.runNode"; payload: { step_id: string } }
  | { type: "execution.cancel" }
  | { type: "revision.open" };

export type WorkflowEditorDispatch = (action: WorkflowEditorAction) => void;

export type WorkflowEditorRootEmits = {
  (event: "action", payload: WorkflowEditorAction): void;
};
