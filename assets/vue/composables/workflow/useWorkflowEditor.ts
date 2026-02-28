import { computed, markRaw, nextTick, onBeforeUnmount, onMounted, ref } from 'vue';
import type { VNodeRef } from 'vue';
import { useLiveEvent } from 'live_vue';
import { VueFlow, useVueFlow } from '@vue-flow/core';
import type { EdgeTypesObject, NodeTypesObject } from '@vue-flow/core';
import WorkflowStepNode from '@/components/flow/Node.vue';
import WorkflowSubNode from '@/components/flow/SubNode.vue';
import GroupNode from '@/components/flow/GroupNode.vue';
import CustomEdge from '@/components/flow/Edge.vue';
import { useClientStore } from '@/stores/clientStore';
import { useUndoStore } from '@/stores/undoStore';
import { useWorkflowEdges } from '@/composables/useWorkflowEdges';
import { useWorkflowGraph } from '@/composables/useWorkflowGraph';
import { useWorkflowNodes } from '@/composables/useWorkflowNodes';
import { useCanvasInteraction } from '@/composables/workflow/useCanvasInteraction';
import { useClipboard } from '@/composables/workflow/useClipboard';
import { useCollaboration } from '@/composables/workflow/useCollaboration';
import { useContextMenu } from '@/composables/workflow/useContextMenu';
import { useDraftSync } from '@/composables/workflow/useDraftSync';
import { useEdgeInteraction } from '@/composables/workflow/useEdgeInteraction';
import { useGrouping } from '@/composables/workflow/useGrouping';
import { useKeyboardShortcuts } from '@/composables/workflow/useKeyboardShortcuts';
import { useLayoutEngine } from '@/composables/workflow/useLayoutEngine';
import { useMiniMapNodeColor } from '@/composables/workflow/useMiniMapNodeColor';
import { useNodeDrag } from '@/composables/workflow/useNodeDrag';
import { useNodeInteraction } from '@/composables/workflow/useNodeInteraction';
import { useWorkflowActions } from '@/composables/workflow/useWorkflowActions';
import { useWorkflowExecutionState } from '@/composables/workflow/useWorkflowExecutionState';
import { useWorkflowNodeActions } from '@/composables/workflow/useWorkflowNodeActions';
import { useWorkflowPins } from '@/composables/workflow/useWorkflowPins';
import { useWorkflowSelection } from '@/composables/workflow/useWorkflowSelection';
import { GRID_SIZE } from '@/constants/layout';
import { findGroupAtPoint, getAbsoluteNodePosition } from '@/lib/workflowGeometry';
import { workflowTrace } from '@/lib/workflowTrace';
import type { StepType, Workflow, WorkflowDraft } from '@/types/workflow';
import type { WorkflowEditorEmits, WorkflowEditorProps } from '@/types/workflowEditor';
export function useWorkflowEditor(props: WorkflowEditorProps, emit: WorkflowEditorEmits) {
  const store = useClientStore();
  const undoStore = useUndoStore();

  // Initialize undo state from props if available
  if (props.undoState) {
    undoStore.handleStateUpdate(props.undoState);
  }
  const sendUndo = () => emit('undo', { count: 1 });
  const sendRedo = () => emit('redo', { count: 1 });
  const handleUndo = () => undoStore.undo(sendUndo);
  const handleRedo = () => undoStore.redo(sendRedo);
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
    getNodes,
    getEdges,
    getSelectedNodes,
    updateNode,
    updateNodeData,
    updateEdge,
    applyNodeChanges,
    applyEdgeChanges,
    removeNodes,
    setNodes,
    setEdges,
    viewport,
    nodesSelectionActive,
  } = useVueFlow();
  const vueFlowRef = ref<InstanceType<typeof VueFlow> | null>(null);
  const syncResetRef = ref<() => void>(() => { });
  const canEdit = computed(() => true);
  const gridSize = GRID_SIZE;
  const isSnapModifierPressed = ref(false);
  const effectiveSnapToGrid = computed(() => store.snapEnabled || isSnapModifierPressed.value);
  const activeWorkflow = computed<Workflow>(() => props.workflow);
  const activeDraft = computed<WorkflowDraft | undefined>(() => props.workflow.draft);
  const collabSeq = computed(() => props.collabSeq ?? 0);
  const nodeActions = useWorkflowNodeActions({ canEdit: () => canEdit.value, emit });
  const pins = useWorkflowPins({ stepExecutions: () => props.stepExecutions ?? [], emit });
  const grouping = useGrouping({
    workflow: () => props.workflow,
    activeDraft: () => activeDraft.value,
    getNodes: () => getNodes.value,
    getSelectedNodes: () => getSelectedNodes.value,
    updateNodeData,
    emit,
  });
  const { nodes } = useWorkflowNodes({
    workflow: () => activeWorkflow.value,
    stepTypes: () => props.stepTypes ?? [],
    stepExecutions: () => props.stepExecutions ?? [],
    editorState: () => props.editorState,
    presences: () => props.presences ?? [],
    currentUserId: () => props.currentUserId,
    canEdit: () => canEdit.value,
    onRunNode: nodeActions.handleRunNode,
    onUpdateGroup: nodeActions.handleUpdateGroup,
    onUpdateStep: nodeActions.handleUpdateStep,
    onMoveSteps: nodeActions.handleMoveSteps,
    onEmitInteraction: (cursor, dragging_steps, dragging_groups) =>
      collaboration.emitInteraction(cursor?.x, cursor?.y, dragging_steps, dragging_groups),
    onCommitDragLayout: payload => emit('commit_drag_layout', payload),
    collabSeq: () => collabSeq.value,
    onToggleDisabled: nodeActions.handleToggleDisabled,
    onTogglePin: pins.handleTogglePin,
    groupingPreview: () => grouping.groupingPreview.value,
  });
  const { edges } = useWorkflowEdges({
    workflow: () => activeWorkflow.value,
    stepExecutions: () => props.stepExecutions ?? [],
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
  const nodeTypes: NodeTypesObject = { step: markRaw(WorkflowStepNode), subnode: markRaw(WorkflowSubNode), group: markRaw(GroupNode) };
  const edgeTypes: EdgeTypesObject = { custom: markRaw(CustomEdge as any) };
  const collaboration = useCollaboration({
    presences: () => props.presences ?? [],
    currentUserId: () => props.currentUserId,
    canEdit: () => canEdit.value,
    getNodes: () => getNodes.value,
    setNodes,
    emit,
    store,
  });
  const handleSelectionChange = (
    event: Parameters<typeof collaboration.handleSelectionChange>[0]
  ) => {
    collaboration.handleSelectionChange(event);

    // Vue Flow clears the multi-selection box on node clicks.
    // Re-enable it for multi-node selections so shift-click matches shift-drag.
    nodesSelectionActive.value = event.nodes.length > 1;
  };
  const canvas = useCanvasInteraction({
    canEdit: () => canEdit.value,
    project,
    getNodes: () => getNodes.value,
    getSelectedNodes: () => getSelectedNodes.value,
    emitInteraction: collaboration.emitInteraction,
    updateGroupingPreview: grouping.updateGroupingPreview,
    onAddStep: payload => emit('add_step', payload),
  });
  const setCanvasRef: VNodeRef = (element) => {
    if (typeof HTMLElement !== 'undefined' && element instanceof HTMLElement) {
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
    if (typeof HTMLElement !== 'undefined' && instance instanceof HTMLElement) {
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
    emit,
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
    emit,
    isSyncingDraft: () => draftSync.isSyncingDraft.value,
  });
  const handleNodeClick = (
    event: Parameters<typeof nodeInteraction.handleNodeClick>[0]
  ) => {
    nodeInteraction.handleNodeClick(event);

    const nativeEvent = event.event;
    if (!(nativeEvent instanceof MouseEvent)) return;
    if (!nativeEvent.shiftKey && !nativeEvent.metaKey && !nativeEvent.ctrlKey) return;

    // Vue Flow clears nodesSelectionActive on node clicks.
    // Re-sync it after modifier-based additive selection updates are applied.
    nextTick(() => {
      nodesSelectionActive.value = getSelectedNodes.value.length > 1;
    });
  };
  const clipboard = useClipboard({
    getNodes: () => getNodes.value,
    getSelectedNodes: () => getSelectedNodes.value,
    setNodes,
    groupByStepId: () => grouping.groupByStepId.value,
    store,
    emit,
    requestNodeRemoval: nodeInteraction.requestNodeRemoval,
    withSelectionLock: collaboration.withSelectionLock,
  });
  const layoutEngine = useLayoutEngine({
    canEdit: () => canEdit.value,
    getNodes: () => getNodes.value,
    getEdges: () => getEdges.value,
    getSelectedNodes: () => getSelectedNodes.value,
    updateNode,
    emit,
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
    emit,
    isSyncingDraft: () => draftSync.isSyncingDraft.value,
  });
  syncResetRef.value = () => { nodeInteraction.resetPendingNodeRemovals(); edgeInteraction.resetPendingEdgeRemovals(); };
  const isAddStepPickerOpen = ref(false);
  const addStepPickerX = ref(0);
  const addStepPickerY = ref(0);
  const openAddStepPicker = (screenPoint: { x: number; y: number }) => {
    addStepPickerX.value = screenPoint.x;
    addStepPickerY.value = screenPoint.y;
    isAddStepPickerOpen.value = true;
  };
  const closeAddStepPicker = () => {
    isAddStepPickerOpen.value = false;
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

    const targetGroup = findGroupAtPoint(position, getNodes.value);
    if (targetGroup) {
      const groupPosition = getAbsoluteNodePosition(targetGroup);
      emit('add_step', {
        type_id: typeId,
        position: {
          x: position.x - groupPosition.x,
          y: position.y - groupPosition.y,
        },
        group_id: targetGroup.id,
      });
    } else {
      emit('add_step', { type_id: typeId, position });
    }

    closeAddStepPicker();
  };
  const contextMenu = useContextMenu({
    store,
    canEdit: () => canEdit.value,
    tidyLabel: () => (getSelectedNodes.value.length > 1 ? 'Tidy Up Selection' : 'Tidy Up Workflow'),
    canPaste: () => clipboard.canPaste.value,
    openAddStepPicker,
    canGroupSelection: () => grouping.canGroupSelection.value,
    canUngroupSelection: () => grouping.canUngroupSelection.value,
    findStepNodeById: nodeInteraction.findStepNodeById,
    resolveActiveNodeIds: clipboard.resolveActiveNodeIds,
    createGroupFromSelection: grouping.createGroupFromSelection,
    ungroupSelectedSteps: grouping.ungroupSelectedSteps,
    removeGroup: grouping.removeGroup,
    handleLayout: layoutEngine.handleLayout,
    handleRunNode: nodeActions.handleRunNode,
    handleToggleDisabled: nodeActions.handleToggleDisabled,
    handleDuplicateSteps: clipboard.handleDuplicateSteps,
    handleCopySteps: clipboard.handleCopySteps,
    handleCutSteps: clipboard.handleCutSteps,
    handlePasteSteps: clipboard.handlePasteSteps,
    requestNodeRemoval: nodeInteraction.requestNodeRemoval,
    handleTogglePin: pins.handleTogglePin,
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
    undo: undoStore.undo,
    redo: undoStore.redo,
    sendUndo,
    sendRedo,
  });
  const actions = useWorkflowActions({ canEdit: () => canEdit.value, emit, requestNodeRemoval: nodeInteraction.requestNodeRemoval, selectNode: store.selectNode });
  const selection = useWorkflowSelection({ nodes: () => nodes.value, selectedNodeId: () => store.selectedNodeId, stepTypes: () => props.stepTypes ?? ([] as StepType[]) });
  const executionState = useWorkflowExecutionState({ execution: () => props.execution });
  const miniMap = useMiniMapNodeColor();
  const closeContextMenu = () => store.hideContextMenu();
  useLiveEvent<any>('workflow:undo_state', payload => {
    undoStore.handleStateUpdate(payload);
  });
  useLiveEvent('workflow:undo_applied', () => undoStore.handleUndoApplied());
  useLiveEvent('workflow:undo_conflict', () => undoStore.handleUndoConflict());
  useLiveEvent('workflow:redo_applied', () => undoStore.handleRedoApplied());
  useLiveEvent('workflow:redo_conflict', () => undoStore.handleRedoConflict());
  useLiveEvent<any>('workflow:operation_ack', payload => {
    workflowTrace('server_ack', payload ?? {});
  });

  const syncSnapModifierState = (event: KeyboardEvent) => {
    isSnapModifierPressed.value = event.metaKey || event.ctrlKey;
  };

  const resetSnapModifierState = () => {
    isSnapModifierPressed.value = false;
  };

  onMounted(() => {
    keyboard.registerShortcuts();
    window.addEventListener('keydown', syncSnapModifierState);
    window.addEventListener('keyup', syncSnapModifierState);
    window.addEventListener('blur', resetSnapModifierState);
  });
  onBeforeUnmount(() => {
    keyboard.unregisterShortcuts();
    window.removeEventListener('keydown', syncSnapModifierState);
    window.removeEventListener('keyup', syncSnapModifierState);
    window.removeEventListener('blur', resetSnapModifierState);
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
    handleRunTest: actions.handleRunTest,
    handleCancelExecution: actions.handleCancelExecution,
    handleRunNode: nodeActions.handleRunNode,
    handleUndo,
    handleRedo,
    handleSaveConfig: actions.handleSaveConfig,
    handleDeleteStep: actions.handleDeleteStep,
    handleSave: actions.handleSave,
    handlePreviewExpression: actions.handlePreviewExpression,
    handleToggleWebhookTest: actions.handleToggleWebhookTest,
    handlePinOutput: pins.handlePinOutput,
    handleUnpinOutput: pins.handleUnpinOutput,
    selectTraceStep: actions.selectTraceStep,
    expressionPreviews: props.expressionPreviews ?? {},
    nodeLibraryItems: props.nodeLibraryItems ?? [],
    execution: props.execution ?? null,
    stepExecutions: props.stepExecutions ?? [],
    editorState: props.editorState,
    presences: props.presences ?? [],
    currentUserId: props.currentUserId,
    workflow: props.workflow,
  };
}
