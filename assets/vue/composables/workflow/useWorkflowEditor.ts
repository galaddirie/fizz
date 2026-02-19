import { computed, markRaw, onBeforeUnmount, onMounted, ref } from 'vue';
import type { VNodeRef } from 'vue';
import { useLiveVue } from 'live_vue';
import { VueFlow, useVueFlow } from '@vue-flow/core';
import type { EdgeTypesObject, NodeTypesObject } from '@vue-flow/core';
import WorkflowStepNode from '@/components/flow/Node.vue';
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
import type { StepType, Workflow, WorkflowDraft } from '@/types/workflow';
import type { WorkflowEditorEmits, WorkflowEditorProps } from '@/types/workflowEditor';
export function useWorkflowEditor(props: WorkflowEditorProps, emit: WorkflowEditorEmits) {
  const store = useClientStore();
  const undoStore = useUndoStore();
  const live = useLiveVue();

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
  } = useVueFlow();
  const vueFlowRef = ref<InstanceType<typeof VueFlow> | null>(null);
  const syncResetRef = ref<() => void>(() => { });
  const canEdit = computed(() => true);
  const activeWorkflow = computed<Workflow>(() => props.workflow);
  const activeDraft = computed<WorkflowDraft | undefined>(() => props.workflow.draft);
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
    onTogglePin: pins.handleTogglePin,
    groupingPreview: () => grouping.groupingPreview.value,
  });
  const { edges } = useWorkflowEdges({
    workflow: () => activeWorkflow.value,
    stepExecutions: () => props.stepExecutions ?? [],
  });
  const draftSync = useDraftSync({ activeDraft: () => activeDraft.value, nodes: () => nodes.value, edges: () => edges.value, setNodes, setEdges, onSyncComplete: () => syncResetRef.value() });
  const { stepNameById, incomingStepIdsByStepId, upstreamStepIdsByStepId } = useWorkflowGraph(
    () => activeWorkflow.value
  );
  const nodeTypes: NodeTypesObject = { step: markRaw(WorkflowStepNode), group: markRaw(GroupNode) };
  const edgeTypes: EdgeTypesObject = { custom: markRaw(CustomEdge as any) };
  const collaboration = useCollaboration({
    presences: () => props.presences ?? [],
    currentUserId: () => props.currentUserId,
    canEdit: () => canEdit.value,
    getSelectedNodes: () => getSelectedNodes.value,
    getNodes: () => getNodes.value,
    setNodes,
    emit,
    store,
  });
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
  const clipboard = useClipboard({
    getNodes: () => getNodes.value,
    getSelectedNodes: () => getSelectedNodes.value,
    setNodes,
    groupByStepId: () => grouping.groupByStepId.value,
    store,
    emit,
    live,
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
  const contextMenu = useContextMenu({
    store,
    canEdit: () => canEdit.value,
    tidyLabel: () => (getSelectedNodes.value.length > 1 ? 'Tidy Up Selection' : 'Tidy Up Workflow'),
    canPaste: () => clipboard.canPaste.value,
    canGroupSelection: () => grouping.canGroupSelection.value,
    canUngroupSelection: () => grouping.canUngroupSelection.value,
    findStepNodeById: nodeInteraction.findStepNodeById,
    resolveActiveNodeIds: clipboard.resolveActiveNodeIds,
    createGroupFromSelection: grouping.createGroupFromSelection,
    ungroupSelectedSteps: grouping.ungroupSelectedSteps,
    removeGroup: grouping.removeGroup,
    handleLayout: layoutEngine.handleLayout,
    handleRunNode: nodeActions.handleRunNode,
    handleDuplicateSteps: clipboard.handleDuplicateSteps,
    handleCopySteps: clipboard.handleCopySteps,
    handleCutSteps: clipboard.handleCutSteps,
    handlePasteSteps: clipboard.handlePasteSteps,
    requestNodeRemoval: nodeInteraction.requestNodeRemoval,
    handleTogglePin: pins.handleTogglePin,
    emit,
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
  onMounted(() => {
    keyboard.registerShortcuts();

    // Listen for undo state updates
    live.handleEvent('undo_state', (payload: any) => {
      undoStore.handleStateUpdate(payload);
    });

    // Listen for undo/redo application results
    live.handleEvent('undo_applied', () => undoStore.handleUndoApplied());
    live.handleEvent('undo_conflict', () => undoStore.handleUndoConflict());
    live.handleEvent('redo_applied', () => undoStore.handleRedoApplied());
    live.handleEvent('redo_conflict', () => undoStore.handleRedoConflict());
  });
  onBeforeUnmount(() => keyboard.unregisterShortcuts());
  onPaneClick(() => store.hideContextMenu());
  return {
    store,
    undoStore,
    nodes,
    edges,
    nodeTypes,
    edgeTypes,
    viewport,
    setCanvasRef,
    setVueFlowRef,
    isMounted: draftSync.isMounted,
    canEdit,
    selectedNode: selection.selectedNode,
    selectedStepType: selection.selectedStepType,
    stepNameById,
    incomingStepIdsByStepId,
    upstreamStepIdsByStepId,
    isExecutionFailed: executionState.isExecutionFailed,
    isExecutionRunning: executionState.isExecutionRunning,
    miniMapNodeColor: miniMap.miniMapNodeColor,
    otherUserPresences: collaboration.otherUserPresences,
    canvasRef: canvas.canvasRef,
    handlePaneMouseMove: canvas.handlePaneMouseMove,
    handleDragOver: canvas.handleDragOver,
    handleDrop: canvas.handleDrop,
    handleNodeClick: nodeInteraction.handleNodeClick,
    handleNodeDoubleClick: nodeInteraction.handleNodeDoubleClick,
    handleNodeContextMenu: nodeInteraction.handleNodeContextMenu,
    handleSelectionChange: collaboration.handleSelectionChange,
    handleSelectionContextMenu: nodeInteraction.handleSelectionContextMenu,
    handlePaneContextMenu: nodeInteraction.handlePaneContextMenu,
    handleEdgeUpdate: edgeInteraction.handleEdgeUpdate,
    contextMenuItems: contextMenu.contextMenuItems,
    handleContextMenuSelect: contextMenu.handleContextMenuSelect,
    closeContextMenu,
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
