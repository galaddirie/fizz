import { reactive } from "vue";

import { useWorkflowEditor } from "@/composables/workflow/useWorkflowEditor";
import type {
  WorkflowSceneController,
  WorkflowSceneModel,
} from "@/shared/ui/workflow-scene/types";

import type {
  WorkflowEditorAction,
  WorkflowEditorViewProps,
} from "../contracts/workflowEditor";
import { useWorkflowEditorChrome } from "./useWorkflowEditorChrome";

export function useWorkflowEditorRoot(
  props: WorkflowEditorViewProps,
  emitAction: (action: WorkflowEditorAction) => void
) {
  const editor = reactive(useWorkflowEditor(props, emitAction));
  const chrome = useWorkflowEditorChrome(props, emitAction);

  const sceneModel: WorkflowSceneModel = {
    get nodes() {
      return editor.nodes;
    },
    get edges() {
      return editor.edges;
    },
    get nodeTypes() {
      return editor.nodeTypes;
    },
    get edgeTypes() {
      return editor.edgeTypes;
    },
    get snapEnabled() {
      return editor.store.snapEnabled;
    },
    get gridSize() {
      return editor.gridSize;
    },
    get effectiveSnapToGrid() {
      return editor.effectiveSnapToGrid;
    },
    get canEdit() {
      return editor.canEdit;
    },
    get miniMapNodeColor() {
      return editor.miniMapNodeColor;
    },
  };

  const sceneController: WorkflowSceneController = {
    setCanvasRef: editor.setCanvasRef,
    setVueFlowRef: editor.setVueFlowRef,
    handlePaneMouseMove: editor.handlePaneMouseMove,
    handleNodeClick: editor.handleNodeClick,
    handleNodeDoubleClick: editor.handleNodeDoubleClick,
    handleNodeContextMenu: editor.handleNodeContextMenu,
    handleSelectionChange: editor.handleSelectionChange,
    handleSelectionContextMenu: editor.handleSelectionContextMenu,
    handlePaneContextMenu: editor.handlePaneContextMenu,
    handleEdgeUpdate: editor.handleEdgeUpdate,
    handleDragOver: editor.handleDragOver,
    handleDrop: editor.handleDrop,
    onRunTest: editor.commands.execution.runTest,
    onCancelExecution: editor.commands.execution.cancel,
    onToggleSnap: editor.store.toggleSnap,
    step: editor.commands.step,
    group: editor.commands.group,
  };

  return {
    editor,
    chrome,
    sceneModel,
    sceneController,
  };
}
