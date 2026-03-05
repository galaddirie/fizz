import { reactive } from 'vue';

import { useRevisionViewer } from '@/composables/workflow/useRevisionViewer';
import { GRID_SIZE } from '@/constants/layout';
import type {
  WorkflowSceneController,
  WorkflowSceneModel,
} from '@/shared/ui/workflow-scene/types';

import type { RevisionViewerAction, RevisionViewerViewProps } from '../contracts/revisionViewer';

export function useRevisionViewerRoot(
  props: RevisionViewerViewProps,
  emitAction: (action: RevisionViewerAction) => void
) {
  const viewer = reactive(useRevisionViewer(props));

  const sceneModel: WorkflowSceneModel = {
    get nodes() {
      return viewer.nodes;
    },
    get edges() {
      return viewer.edges;
    },
    get nodeTypes() {
      return viewer.nodeTypes;
    },
    get edgeTypes() {
      return viewer.edgeTypes;
    },
    snapEnabled: false,
    gridSize: GRID_SIZE,
    effectiveSnapToGrid: false,
    canEdit: false,
    isPreviewActive: false,
    previewLabel: '',
    get isMounted() {
      return viewer.isMounted;
    },
    otherUserPresences: [],
    currentUserId: undefined,
    get viewport() {
      return viewer.viewport;
    },
    get miniMapNodeColor() {
      return viewer.miniMapNodeColor;
    },
    isExecutionFailed: false,
    isExecutionRunning: false,
    workflowExecutionsLink: null,
  };

  const sceneController: WorkflowSceneController = {
    setCanvasRef: viewer.setCanvasRef,
    setVueFlowRef: viewer.setVueFlowRef,
    handleNodeClick: viewer.handleNodeClick,
    handleNodeDoubleClick: viewer.handleNodeDoubleClick,
    handleSelectionChange: viewer.handleSelectionChange,
  };

  const workspaceLink = props.document.workflow.workspace_id
    ? `/workspaces/${props.document.workflow.workspace_id}`
    : null;

  return {
    viewer,
    sceneModel,
    sceneController,
    workspaceLink,
    emitSelectCurrent: () => emitAction({ type: 'history.selectCurrent' }),
    emitSelectUndo: (depth: number) =>
      emitAction({ type: 'history.selectUndo', payload: { depth } }),
    emitSelectVersion: (id: string) =>
      emitAction({ type: 'history.selectVersion', payload: { id } }),
    emitApply: () => emitAction({ type: 'history.apply' }),
    emitBack: () => emitAction({ type: 'navigation.backToEditor' }),
  };
}
