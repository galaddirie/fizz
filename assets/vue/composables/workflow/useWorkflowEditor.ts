import {
  computed,
  markRaw,
  nextTick,
  onBeforeUnmount,
  onMounted,
  ref,
  watch,
} from "vue";
import type { VNodeRef } from "vue";
import { useLiveEvent } from "live_vue";
import { VueFlow, useVueFlow } from "@vue-flow/core";
import type {
  EdgeTypesObject,
  GraphNode,
  NodeTypesObject,
  XYPosition,
} from "@vue-flow/core";
import WorkflowStepNode from "@/components/flow/Node.vue";
import WorkflowSubNode from "@/components/flow/SubNode.vue";
import GroupNode from "@/components/flow/GroupNode.vue";
import { useClientStore } from "@/stores/clientStore";
import { useUndoStore } from "@/stores/undoStore";
import { useWorkflowEdges } from "@/composables/useWorkflowEdges";
import { useWorkflowGraph } from "@/composables/useWorkflowGraph";
import { useWorkflowNodes } from "@/composables/useWorkflowNodes";
import { useCanvasInteraction } from "@/composables/workflow/useCanvasInteraction";
import { useClipboard } from "@/composables/workflow/useClipboard";
import { useCollaboration } from "@/composables/workflow/useCollaboration";
import { useContextMenu } from "@/composables/workflow/useContextMenu";
import { useDraftSync } from "@/composables/workflow/useDraftSync";
import { useEdgeInteraction } from "@/composables/workflow/useEdgeInteraction";
import { useGrouping } from "@/composables/workflow/useGrouping";
import { useKeyboardShortcuts } from "@/composables/workflow/useKeyboardShortcuts";
import { useLayoutEngine } from "@/composables/workflow/useLayoutEngine";
import { useMiniMapNodeColor } from "@/composables/workflow/useMiniMapNodeColor";
import { useNodeDrag } from "@/composables/workflow/useNodeDrag";
import { useNodeInteraction } from "@/composables/workflow/useNodeInteraction";
import { useWorkflowCommands } from "@/composables/workflow/useWorkflowCommands";
import { useWorkflowExecutionState } from "@/composables/workflow/useWorkflowExecutionState";
import { useWorkflowSelection } from "@/composables/workflow/useWorkflowSelection";
import { DEFAULT_NODE_DIMENSIONS, GRID_SIZE } from "@/constants/layout";
import {
  findGroupAtPoint,
  getAbsoluteNodePosition,
} from "@/lib/workflowGeometry";
import { workflowTrace } from "@/lib/workflowTrace";
import { workflowEdgeTypes } from "@/shared/ui/workflow-scene/edgeTypes";
import type {
  WorkflowNodeData,
  WorkflowSceneController,
} from "@/shared/ui/workflow-scene/types";
import type { UndoState } from "@/stores/undoStore";
import type {
  NodeLibraryItem,
  StepHandleQuickAddRequest,
  Workflow,
  WorkflowDraft,
} from "@/types/workflow";
import type {
  WorkflowEditorAction,
  WorkflowEditorDispatch,
  WorkflowEditorViewProps,
} from "@/features/workflow-editor/contracts/workflowEditor";

const SUBNODE_FALLBACK_DIMENSIONS = { width: 112, height: 96 };
const QUICK_ADD_OUTPUT_X_OFFSET = GRID_SIZE * 3;

type AddStepPayload = Extract<
  WorkflowEditorAction,
  { type: "document.step.add" }
>["payload"];

type WorkflowCanvasNode = GraphNode<WorkflowNodeData>;

export const buildAddStepPickerItems = (
  nodeLibraryItems: NodeLibraryItem[],
  quickAddRequest: StepHandleQuickAddRequest | null
) => {
  if (!quickAddRequest) return nodeLibraryItems;

  if (quickAddRequest.filter.mode === "output") {
    return nodeLibraryItems.filter(
      (item) => item.node_role !== "subnode" && item.step_kind !== "trigger"
    );
  }

  const acceptedTypeIds = quickAddRequest.filter.accepted_type_ids ?? [];

  return nodeLibraryItems.filter((item) => {
    if (item.node_role !== "subnode") return false;
    if (acceptedTypeIds.length === 0) return true;
    return acceptedTypeIds.includes(item.type_id);
  });
};

export const resolveAddStepSize = (
  nodeLibraryItems: NodeLibraryItem[],
  nodes: WorkflowCanvasNode[],
  typeId: string
) => {
  const selectedItem = nodeLibraryItems.find((item) => item.type_id === typeId);
  const isSubnode = selectedItem?.node_role === "subnode";
  const nodeType = isSubnode ? "subnode" : "step";
  const measuredNode = nodes.find(
    (node) =>
      node.type === nodeType &&
      node.dimensions.width > 0 &&
      node.dimensions.height > 0
  );

  if (measuredNode) {
    return {
      width: measuredNode.dimensions.width,
      height: measuredNode.dimensions.height,
    };
  }

  return isSubnode ? SUBNODE_FALLBACK_DIMENSIONS : DEFAULT_NODE_DIMENSIONS;
};

const resolveAddStepPosition = (
  position: XYPosition,
  quickAddRequest: StepHandleQuickAddRequest | null,
  stepSize: { width: number; height: number }
) =>
  quickAddRequest?.filter.mode === "output"
    ? {
        x: position.x + QUICK_ADD_OUTPUT_X_OFFSET,
        y: position.y - stepSize.height / 2,
      }
    : position;

const resolveQuickAddTargetGroup = (
  nodes: WorkflowCanvasNode[],
  resolvedPosition: XYPosition,
  quickAddRequest: StepHandleQuickAddRequest | null,
  groupByStepId: Map<string, string>
) => {
  let targetGroup = findGroupAtPoint(resolvedPosition, nodes);
  if (targetGroup || !quickAddRequest) return targetGroup;

  const fixedStepId =
    quickAddRequest.autoConnect.source_step_id ??
    quickAddRequest.autoConnect.target_step_id;
  const fixedGroupId = fixedStepId ? groupByStepId.get(fixedStepId) : undefined;

  if (!fixedGroupId) return null;

  return nodes.find(
    (node) => node.id === fixedGroupId && node.type === "group"
  );
};

const buildAddStepPayload = (params: {
  typeId: string;
  position: XYPosition;
  quickAddRequest: StepHandleQuickAddRequest | null;
  nodeLibraryItems: NodeLibraryItem[];
  nodes: WorkflowCanvasNode[];
  groupByStepId: Map<string, string>;
}): AddStepPayload => {
  const stepSize = resolveAddStepSize(
    params.nodeLibraryItems,
    params.nodes,
    params.typeId
  );
  const resolvedPosition = resolveAddStepPosition(
    params.position,
    params.quickAddRequest,
    stepSize
  );
  const payload: AddStepPayload = {
    type_id: params.typeId,
    position: resolvedPosition,
    step_size: stepSize,
  };

  if (params.quickAddRequest?.autoConnect) {
    payload.auto_connect = params.quickAddRequest.autoConnect;
  }

  const targetGroup = resolveQuickAddTargetGroup(
    params.nodes,
    resolvedPosition,
    params.quickAddRequest,
    params.groupByStepId
  );

  if (!targetGroup) return payload;

  const groupPosition = getAbsoluteNodePosition(targetGroup);
  payload.position = {
    x: resolvedPosition.x - groupPosition.x,
    y: resolvedPosition.y - groupPosition.y,
  };
  payload.group_id = targetGroup.id;

  return payload;
};

export function useWorkflowEditor(
  props: WorkflowEditorViewProps,
  dispatch: WorkflowEditorDispatch
) {
  const store = useClientStore();
  const undoStore = useUndoStore();

  // Initialize undo state from props if available
  if (props.document.undoState) {
    undoStore.handleStateUpdate(props.document.undoState);
  }
  undoStore.configureTransport({
    requestUndo: () =>
      dispatch({ type: "document.undo", payload: { count: 1 } }),
    requestRedo: () =>
      dispatch({ type: "document.redo", payload: { count: 1 } }),
  });

  const {
    onPaneClick,
    onConnect,
    onNodesChange,
    onEdgesChange,
    onNodeDragStart,
    onNodeDragStop,
    onNodeDrag,
    onMoveStart,
    project,
    fitView,
    getNodes,
    getEdges,
    getSelectedNodes,
    updateNode,
    updateNodeData,
    updateEdge,
    addSelectedNodes,
    applyNodeChanges,
    applyEdgeChanges,
    removeNodes,
    setNodes,
    setEdges,
    viewport,
    nodesSelectionActive,
  } = useVueFlow();
  const vueFlowRef = ref<InstanceType<typeof VueFlow> | null>(null);
  const syncResetRef = ref<() => void>(() => {});
  const canEdit = computed(() => true);
  const gridSize = GRID_SIZE;
  const isSnapModifierPressed = ref(false);
  const effectiveSnapToGrid = computed(
    () => store.snapEnabled || isSnapModifierPressed.value
  );
  const activeWorkflow = computed<Workflow>(() => props.document.workflow);
  const activeDraft = computed<WorkflowDraft | undefined>(
    () => props.document.workflow.draft
  );
  const collabSeq = computed(() => props.collaboration.collabSeq);
  const activeExpressionPreviews = computed(
    () => props.document.expressionPreviews
  );
  const activeExecution = computed(() => props.execution.execution);
  const activeStepExecutions = computed(() => props.execution.stepExecutions);
  const activeEditorState = computed(() => props.document.editorState);
  const activePresences = computed(() => props.collaboration.presences);
  const activeCurrentUserId = computed(() => props.collaboration.currentUserId);
  const grouping = useGrouping({
    workflow: () => props.document.workflow,
    activeDraft: () => activeDraft.value,
    getCollabSeq: () => collabSeq.value,
    getNodes: () => getNodes.value,
    getSelectedNodes: () => getSelectedNodes.value,
    updateNodeData,
    dispatch,
  });

  function handleNodeHandleQuickAdd(request: StepHandleQuickAddRequest) {
    openAddStepPicker(request.screenPoint, request);
  }

  const { nodes } = useWorkflowNodes({
    workflow: () => activeWorkflow.value,
    stepTypes: () => props.catalog.stepTypes,
    stepExecutions: () => props.execution.stepExecutions,
    editorState: () => props.document.editorState,
    presences: () => props.collaboration.presences,
    currentUserId: () => props.collaboration.currentUserId,
    canEdit: () => canEdit.value,
    collabSeq: () => collabSeq.value,
    groupingPreview: () => grouping.groupingPreview.value,
  });
  const { edges } = useWorkflowEdges({
    workflow: () => activeWorkflow.value,
    stepExecutions: () => props.execution.stepExecutions,
  });
  const draftSync = useDraftSync({
    activeDraft: () => activeDraft.value,
    collabSeq: () => collabSeq.value,
    nodes: () => nodes.value,
    edges: () => edges.value,
    setNodes,
    setEdges,
    onSyncComplete: () => syncResetRef.value(),
  });
  const {
    stepNameById,
    incomingStepIdsByStepId,
    incomingConnectionsByTargetInputByStepId,
    upstreamStepIdsByStepId,
  } = useWorkflowGraph(() => activeWorkflow.value);
  const nodeTypes: NodeTypesObject = {
    step: markRaw(WorkflowStepNode),
    subnode: markRaw(WorkflowSubNode),
    group: markRaw(GroupNode),
  };
  const edgeTypes: EdgeTypesObject = workflowEdgeTypes;
  const collaboration = useCollaboration({
    presences: () => props.collaboration.presences,
    currentUserId: () => props.collaboration.currentUserId,
    canEdit: () => canEdit.value,
    getNodes: () => getNodes.value,
    setNodes,
    dispatch,
    store,
  });
  const syncSelectionState = () => {
    const selectedNodes = getSelectedNodes.value as Parameters<
      typeof collaboration.handleSelectionChange
    >[0]["nodes"];

    collaboration.handleSelectionChange({ nodes: selectedNodes });
    nodesSelectionActive.value = selectedNodes.length > 1;
  };
  const handleSelectionChange = (
    event: Parameters<typeof collaboration.handleSelectionChange>[0]
  ) => {
    collaboration.handleSelectionChange(event);
    nodesSelectionActive.value = event.nodes.length > 1;
  };
  watch(
    () =>
      getSelectedNodes.value
        .map((node) => node.id)
        .sort((left, right) => left.localeCompare(right))
        .join(","),
    () => {
      syncSelectionState();
    },
    { flush: "sync", immediate: true }
  );
  const canvas = useCanvasInteraction({
    canEdit: () => canEdit.value,
    project,
    getNodes: () => getNodes.value,
    getSelectedNodes: () => getSelectedNodes.value,
    emitInteraction: collaboration.emitInteraction,
    updateGroupingPreview: grouping.updateGroupingPreview,
    onAddStep: (payload) => dispatch({ type: "document.step.add", payload }),
  });
  const setCanvasRef: VNodeRef = (element) => {
    if (typeof HTMLElement !== "undefined" && element instanceof HTMLElement) {
      canvas.canvasRef.value = element;
      return;
    }
    canvas.canvasRef.value = null;
  };
  const setVueFlowRef: VNodeRef = (instance) => {
    if (!instance) {
      vueFlowRef.value = null;
      return;
    }
    if (typeof HTMLElement !== "undefined" && instance instanceof HTMLElement) {
      vueFlowRef.value = null;
      return;
    }
    vueFlowRef.value = instance as InstanceType<typeof VueFlow>;
  };
  useNodeDrag({
    canEdit: () => canEdit.value,
    gridSize: () => gridSize,
    snapEnabled: () => store.snapEnabled,
    getCollabSeq: () => collabSeq.value,
    getNodes: () => getNodes.value,
    groupByStepId: () => grouping.groupByStepId.value,
    updateNode,
    dispatch,
    emitInteraction: collaboration.emitInteraction,
    updateGroupingPreview: grouping.updateGroupingPreview,
    clearGroupingPreview: grouping.clearGroupingPreview,
    getFlowPositionFromEvent: canvas.getFlowPositionFromEvent,
    onNodeDrag,
    onNodeDragStart,
    onNodeDragStop,
  });
  const nodeInteraction = useNodeInteraction({
    canEdit: () => canEdit.value,
    getCollabSeq: () => collabSeq.value,
    store,
    nodes: () => nodes.value,
    getNodes: () => getNodes.value,
    setNodes,
    applyNodeChanges,
    removeNodes,
    onNodesChange,
    project,
    canvasRef: canvas.canvasRef,
    vueFlowRef,
    dispatch,
    isSyncingDraft: () => draftSync.isSyncingDraft.value,
  });
  const workflowCommands = useWorkflowCommands({
    canEdit: () => canEdit.value,
    dispatch,
    stepExecutions: () => props.execution.stepExecutions,
    requestNodeRemoval: nodeInteraction.requestNodeRemoval,
    selectNode: store.selectNode,
  });
  const handleNodeClick = (
    event: Parameters<typeof nodeInteraction.handleNodeClick>[0]
  ) => {
    nodeInteraction.handleNodeClick(event);

    const nativeEvent = event.event;
    if (!(nativeEvent instanceof MouseEvent)) return;
    if (!nativeEvent.shiftKey && !nativeEvent.metaKey && !nativeEvent.ctrlKey)
      return;

    // Vue Flow clears nodesSelectionActive on node clicks.
    // Re-sync it after modifier-based additive selection updates are applied.
    nextTick(() => {
      syncSelectionState();
    });
  };
  const clipboard = useClipboard({
    getNodes: () => getNodes.value,
    getSelectedNodes: () => getSelectedNodes.value,
    setNodes,
    groupByStepId: () => grouping.groupByStepId.value,
    store,
    dispatch,
    requestNodeRemoval: nodeInteraction.requestNodeRemoval,
    withSelectionLock: collaboration.withSelectionLock,
  });
  const layoutEngine = useLayoutEngine({
    canEdit: () => canEdit.value,
    getNodes: () => getNodes.value,
    getEdges: () => getEdges.value,
    getSelectedNodes: () => getSelectedNodes.value,
    updateNode,
    dispatch,
  });
  const edgeInteraction = useEdgeInteraction({
    canEdit: () => canEdit.value,
    getEdges: () => getEdges.value,
    updateEdge,
    onConnect,
    onEdgesChange,
    applyEdgeChanges,
    setEdges,
    getConnections: () => activeDraft.value?.connections ?? [],
    dispatch,
    isSyncingDraft: () => draftSync.isSyncingDraft.value,
  });
  syncResetRef.value = () => {
    nodeInteraction.resetPendingNodeRemovals();
    edgeInteraction.resetPendingEdgeRemovals();
  };
  const nodeLibraryItems = computed<NodeLibraryItem[]>(
    () => props.catalog.nodeLibraryItems
  );
  const isAddStepPickerOpen = ref(false);
  const addStepPickerX = ref(0);
  const addStepPickerY = ref(0);
  const pendingHandleQuickAdd = ref<StepHandleQuickAddRequest | null>(null);
  const addStepPickerItems = computed<NodeLibraryItem[]>(() =>
    buildAddStepPickerItems(nodeLibraryItems.value, pendingHandleQuickAdd.value)
  );

  const openAddStepPicker = (
    screenPoint: { x: number; y: number },
    quickAddRequest: StepHandleQuickAddRequest | null = null
  ) => {
    addStepPickerX.value = screenPoint.x;
    addStepPickerY.value = screenPoint.y;
    pendingHandleQuickAdd.value = quickAddRequest;
    isAddStepPickerOpen.value = true;
  };
  const closeAddStepPicker = () => {
    isAddStepPickerOpen.value = false;
    pendingHandleQuickAdd.value = null;
  };
  const handleAddStepPickerSelect = (typeId: string) => {
    const position = canvas.getFlowPositionFromEvent({
      clientX: addStepPickerX.value,
      clientY: addStepPickerY.value,
    });

    if (!position) {
      closeAddStepPicker();
      return;
    }

    const addStepPayload = buildAddStepPayload({
      typeId,
      position,
      quickAddRequest: pendingHandleQuickAdd.value,
      nodeLibraryItems: nodeLibraryItems.value,
      nodes: getNodes.value,
      groupByStepId: grouping.groupByStepId.value,
    });

    dispatch({ type: "document.step.add", payload: addStepPayload });
    closeAddStepPicker();
  };
  const stepCommands = {
    ...workflowCommands.step,
    quickAdd: handleNodeHandleQuickAdd,
  } satisfies NonNullable<WorkflowSceneController["step"]>;
  const groupCommands = {
    ...workflowCommands.group,
    commitDragLayout: (payload) =>
      dispatch({ type: "document.layout.commit", payload }),
    emitInteraction: (cursor, draggingSteps, draggingGroups) =>
      collaboration.emitInteraction(
        cursor?.x,
        cursor?.y,
        draggingSteps,
        draggingGroups
      ),
  } satisfies NonNullable<WorkflowSceneController["group"]>;
  const commands = {
    document: {
      save: workflowCommands.document.save,
      undo: undoStore.requestUndo,
      redo: undoStore.requestRedo,
    },
    execution: workflowCommands.execution,
    selection: workflowCommands.selection,
    inspector: workflowCommands.inspector,
    step: stepCommands,
    group: groupCommands,
  };
  const contextMenu = useContextMenu({
    store,
    canEdit: () => canEdit.value,
    state: {
      tidyLabel: () =>
        getSelectedNodes.value.length > 1
          ? "Tidy Up Selection"
          : "Tidy Up Workflow",
      canPaste: () => clipboard.canPaste.value,
      canGroupSelection: () => grouping.canGroupSelection.value,
      canUngroupSelection: () => grouping.canUngroupSelection.value,
    },
    lookup: {
      findStepNodeById: nodeInteraction.findStepNodeById,
      resolveActiveNodeIds: clipboard.resolveActiveNodeIds,
    },
    commands: {
      canvas: {
        openAddStepPicker,
        fitView,
        selectAll: () => addSelectedNodes(getNodes.value),
      },
      group: {
        createFromSelection: grouping.createGroupFromSelection,
        ungroupSelection: grouping.ungroupSelectedSteps,
        remove: grouping.removeGroup,
        tidy: layoutEngine.handleLayout,
      },
      clipboard: {
        duplicate: clipboard.handleDuplicateSteps,
        copy: clipboard.handleCopySteps,
        cut: clipboard.handleCutSteps,
        paste: clipboard.handlePasteSteps,
      },
      step: {
        inspect: store.openConfigModal,
        remove: nodeInteraction.requestNodeRemoval,
        run: commands.step.run,
        toggleDisabled: commands.step.toggleDisabled,
        togglePin: commands.step.togglePin,
      },
    },
  });
  const keyboard = useKeyboardShortcuts({
    canEdit: () => canEdit.value,
    canPaste: () => clipboard.canPaste.value,
    canGroupSelection: () => grouping.canGroupSelection.value,
    canUngroupSelection: () => grouping.canUngroupSelection.value,
    resolveActiveNodeIds: () => clipboard.resolveActiveNodeIds(),
    handleCopySteps: clipboard.handleCopySteps,
    handlePasteSteps: clipboard.handlePasteSteps,
    handleCutSteps: clipboard.handleCutSteps,
    createGroupFromSelection: grouping.createGroupFromSelection,
    ungroupSelectedSteps: grouping.ungroupSelectedSteps,
    requestUndo: commands.document.undo,
    requestRedo: commands.document.redo,
  });
  const selection = useWorkflowSelection({
    nodes: () => nodes.value,
    selectedNodeId: () => store.selectedNodeId,
    stepTypes: () => props.catalog.stepTypes,
  });
  const executionState = useWorkflowExecutionState({
    execution: () => props.execution.execution,
  });
  const miniMap = useMiniMapNodeColor();
  const closeContextMenu = () => store.hideContextMenu();
  useLiveEvent<UndoState>("workflow:undo_state", (payload) => {
    undoStore.handleStateUpdate(payload);
  });
  useLiveEvent("workflow:undo_applied", () => undoStore.resolveUndoRequest());
  useLiveEvent("workflow:undo_conflict", () => undoStore.resolveUndoRequest());
  useLiveEvent("workflow:redo_applied", () => undoStore.resolveRedoRequest());
  useLiveEvent("workflow:redo_conflict", () => undoStore.resolveRedoRequest());
  useLiveEvent<Record<string, unknown> | null>(
    "workflow:operation_ack",
    (payload) => {
      workflowTrace("server_ack", payload ?? {});
    }
  );

  const syncSnapModifierState = (event: KeyboardEvent) => {
    isSnapModifierPressed.value = event.metaKey || event.ctrlKey;
  };

  const resetSnapModifierState = () => {
    isSnapModifierPressed.value = false;
  };

  onMounted(() => {
    keyboard.registerShortcuts();
    window.addEventListener("keydown", syncSnapModifierState);
    window.addEventListener("keyup", syncSnapModifierState);
    window.addEventListener("blur", resetSnapModifierState);
  });
  onBeforeUnmount(() => {
    keyboard.unregisterShortcuts();
    window.removeEventListener("keydown", syncSnapModifierState);
    window.removeEventListener("keyup", syncSnapModifierState);
    window.removeEventListener("blur", resetSnapModifierState);
  });
  onPaneClick(() => {
    store.hideContextMenu();
    closeAddStepPicker();
  });
  onMoveStart(() => {
    store.hideContextMenu();
    closeAddStepPicker();
  });
  onNodeDragStart(() => {
    store.hideContextMenu();
    closeAddStepPicker();
  });
  return {
    store,
    undoStore,
    nodes,
    edges,
    nodeTypes,
    edgeTypes,
    gridSize,
    effectiveSnapToGrid,
    viewport,
    setCanvasRef,
    setVueFlowRef,
    isMounted: draftSync.isMounted,
    canEdit,
    selectedNode: selection.selectedNode,
    selectedStepType: selection.selectedStepType,
    stepNameById,
    incomingStepIdsByStepId,
    incomingConnectionsByTargetInputByStepId,
    upstreamStepIdsByStepId,
    isExecutionFailed: executionState.isExecutionFailed,
    isExecutionRunning: executionState.isExecutionRunning,
    miniMapNodeColor: miniMap.miniMapNodeColor,
    otherUserPresences: collaboration.otherUserPresences,
    canvasRef: canvas.canvasRef,
    handlePaneMouseMove: canvas.handlePaneMouseMove,
    handleDragOver: canvas.handleDragOver,
    handleDrop: canvas.handleDrop,
    handleNodeClick,
    handleNodeDoubleClick: nodeInteraction.handleNodeDoubleClick,
    handleNodeContextMenu: nodeInteraction.handleNodeContextMenu,
    handleSelectionChange,
    handleSelectionContextMenu: nodeInteraction.handleSelectionContextMenu,
    handlePaneContextMenu: nodeInteraction.handlePaneContextMenu,
    handleEdgeUpdate: edgeInteraction.handleEdgeUpdate,
    contextMenuItems: contextMenu.contextMenuItems,
    handleContextMenuSelect: contextMenu.handleContextMenuSelect,
    closeContextMenu,
    isAddStepPickerOpen,
    addStepPickerX,
    addStepPickerY,
    closeAddStepPicker,
    handleAddStepPickerSelect,
    commands,
    expressionPreviews: activeExpressionPreviews,
    nodeLibraryItems,
    addStepPickerItems,
    execution: activeExecution,
    stepExecutions: activeStepExecutions,
    editorState: activeEditorState,
    presences: activePresences,
    currentUserId: activeCurrentUserId,
    workflow: activeWorkflow,
  };
}
