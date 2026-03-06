import type { Workflow } from "@/types/workflow";

export interface WorkflowDocumentView extends Workflow {
  workspace_id?: string;
  workspace?: {
    name?: string;
  };
}
