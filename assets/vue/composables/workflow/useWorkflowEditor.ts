import { computed, markRaw, nextTick, onBeforeUnmount, onMounted, ref, shallowRef, watch } from 'vue';
import type { VNodeRef } from 'vue';
import { useLiveEvent } from 'live_vue';
import { VueFlow, useVueFlow } from '@vue-flow/core';
import type { EdgeTypesObject, NodeTypesObject, XYPosition } from '@vue-flow/core';
import WorkflowStepNode from '@/components/flow/Node.vue';
import WorkflowSubNode from '@/components/flow/SubNode.vue';
import GroupNode from '@/components/flow/GroupNode.vue';
import CustomEdge from '@/components/flow/Edge.vue';
import { useClientStore } from '@/stores/clientStore';
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
import { useWorkflowNodeActions } from '@/composables/workflow/useWorkflowNodeActions';
import { useWorkflowPins } from '@/composables/workflow/useWorkflowPins';
import { DEFAULT_NODE_DIMENSIONS, GRID_SIZE } from '@/constants/layout';
import { findGroupAtPoint, getAbsoluteNodePosition } from '@/lib/workflowGeometry';
import { isStepNode } from '@/lib/workflowGuards';
import { workflowTrace } from '@/lib/workflowTrace';
import type {
  NodeLibraryItem,
  StepHandleQuickAddRequest,
  StepNodeData,
  StepType,
  Workflow,
  WorkflowDraft,
} from '@/types/workflow';
import type {
  WorkflowEditorCommandType,
  WorkflowEditorEmits,
  WorkflowEditorProps,
} from '@/types/workflowEditor';

const SUBNODE_FALLBACK_DIMENSIONS = { width: 112, height: 96 };
const QUICK_ADD_OUTPUT_X_OFFSET = GRID_SIZE * 3;

type GroupBounds = { x: number; y: number; width: number; height: number };

type CommitDragLayoutPayload = {
  txn_id: string;
  base_seq?: number;
  groups: Array<{ group_id: string; position: GroupBounds }>;
  step_positions: Record<string, XYPosition>;
  group_id_by_step_id: Record<string, string | null>;
};

type OptimisticLayoutState = {
  txnId: string;
  targetSeq: number | null;
  stepPositions: Record<string, XYPosition>;
  groupBoundsById: Record<string, GroupBounds>;
  groupIdByStepId: Record<string, string | null>;
};

const readNumberField = (value: unknown, key: string): number | null => {
  if (!value || typeof value !== 'object') return null;

  const field = (value as Record<string, unknown>)[key];
  return typeof field === 'number' && Number.isFinite(field) ? field : null;
};

const positionsMatch = (value: unknown, expected: XYPosition) => {
  return readNumberField(value, 'x') === expected.x && readNumberField(value, 'y') === expected.y;
};

const boundsMatch = (value: unknown, expected: GroupBounds) => {
  return (
    readNumberField(value, 'x') === expected.x &&
    readNumberField(value, 'y') === expected.y &&
    readNumberField(value, 'width') === expected.width &&
    readNumberField(value, 'height') === expected.height
  );
};

const groupMembershipByStepId = (draft: WorkflowDraft | undefined) => {
  const memberships = new Map<string, string | null>();

  for (const group of draft?.step_groups ?? []) {
    for (const stepId of group.step_ids ?? []) {
      memberships.set(stepId, group.id);
    }
  }

  return memberships;
};

const draftMatchesOptimisticLayout = (
  draft: WorkflowDraft | undefined,
  layout: OptimisticLayoutState | null
) => {
  if (!draft || !layout) return false;

  const stepsById = new Map((draft.steps ?? []).map(step => [step.id, step]));
  const groupsById = new Map((draft.step_groups ?? []).map(group => [group.id, group]));
  const memberships = groupMembershipByStepId(draft);

  for (const [stepId, position] of Object.entries(layout.stepPositions)) {
    const step = stepsById.get(stepId);
    if (!step || !positionsMatch(step.position, position)) return false;
  }

  for (const [groupId, bounds] of Object.entries(layout.groupBoundsById)) {
    const group = groupsById.get(groupId);
    if (!group || !boundsMatch(group.position, bounds)) return false;
  }

  for (const [stepId, groupId] of Object.entries(layout.groupIdByStepId)) {
    if ((memberships.get(stepId) ?? null) !== groupId) return false;
  }

  return true;
};

export function useWorkflowEditor(props: WorkflowEditorProps, emit: WorkflowEditorEmits) {
  const store = useClientStore();

  // Undo state — driven entirely from server props
  const isUndoPending = ref(false);
  const canUndo = computed(() => (props.undoState?.canUndo ?? false) && !isUndoPending.value);
  const canRedo = computed(() => (props.undoState?.canRedo ?? false) && !isUndoPending.value);
  const undoTooltip = computed(() =>
    props.undoState?.undoLabel ? `Undo: ${props.undoState.undoLabel} (⌘Z)` : 'Nothing to undo'
  );
  const redoTooltip = computed(() =>
    props.undoState?.redoLabel ? `Redo: ${props.undoState.redoLabel} (⌘⇧Z)` : 'Nothing to redo'
  );
  const clearUndoPending = () => {
    isUndoPending.value = false;
  };
  // Consecutive undo/redo operations can produce the same visible labels, so
  // don't rely on undoState alone to release the pending flag.
  watch(() => props.collabSeq ?? 0, clearUndoPending);
  watch(() => props.undoState, clearUndoPending, { deep: true });

  const handleUndo = () => {
    if (!canUndo.value) return;
    isUndoPending.value = true;
    emit('undo', { count: 1 });
  };
  const handleRedo = () => {
    if (!canRedo.value) return;
    isUndoPending.value = true;
    emit('redo', { count: 1 });
  };
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
  const isLocalDragActive = ref(false);
  const optimisticLayout = ref<OptimisticLayoutState | null>(null);
  const setOptimisticLayout = (payload: CommitDragLayoutPayload) => {
    optimisticLayout.value = {
      txnId: payload.txn_id,
      targetSeq: null,
      stepPositions: { ...payload.step_positions },
      groupBoundsById: Object.fromEntries(
        payload.groups.map(({ group_id, position }) => [group_id, { ...position }])
      ),
      groupIdByStepId: { ...payload.group_id_by_step_id },
    };
  };
  const maybeClearOptimisticLayout = (layout: OptimisticLayoutState | null = optimisticLayout.value) => {
    if (!layout) return;

    if (draftMatchesOptimisticLayout(activeDraft.value, layout)) {
      optimisticLayout.value = null;
      return;
    }

    if (layout.targetSeq !== null && collabSeq.value > layout.targetSeq) {
      optimisticLayout.value = null;
    }
  };
  const emitEditor = ((event: WorkflowEditorCommandType, payload?: unknown) => {
    if (event === 'commit_drag_layout' && payload) {
      setOptimisticLayout(payload as CommitDragLayoutPayload);
    }

    emit(event as never, payload as never);
  }) as WorkflowEditorEmits;
  const nodeActions = useWorkflowNodeActions({ canEdit: () => canEdit.value, emit: emitEditor });
  const pins = useWorkflowPins({
    stepExecutions: () => props.stepExecutions ?? [],
    emit: emitEditor,
  });
  const grouping = useGrouping({
    workflow: () => props.workflow,
    activeDraft: () => activeDraft.value,
    getCollabSeq: () => collabSeq.value,
    getNodes: () => getNodes.value,
    getSelectedNodes: () => getSelectedNodes.value,
    updateNodeData,
    emit: emitEditor,
  });

  function handleNodeHandleQuickAdd(request: StepHandleQuickAddRequest) {
    openAddStepPicker(request.screenPoint, request);
  }

  const { nodes } = useWorkflowNodes({
    workflow: () => activeWorkflow.value,
    stepTypes: () => props.stepTypes ?? [],
    stepExecutions: () => props.stepExecutions ?? [],
    editorState: () => props.editorState,
    validationErrors: () => props.validationErrors ?? {},
    presences: () => props.presences ?? [],
    currentUserId: () => props.currentUserId,
    canEdit: () => canEdit.value,
    onRunNode: nodeActions.handleRunNode,
    onUpdateGroup: nodeActions.handleUpdateGroup,
    onUpdateStep: nodeActions.handleUpdateStep,
    onMoveSteps: nodeActions.handleMoveSteps,
    onEmitInteraction: (cursor, dragging_steps, dragging_groups) =>
      collaboration.emitInteraction(cursor?.x, cursor?.y, dragging_steps, dragging_groups),
    onCommitDragLayout: payload => emitEditor('commit_drag_layout', payload),
    collabSeq: () => collabSeq.value,
    optimisticLayout: () => optimisticLayout.value,
    onToggleDisabled: nodeActions.handleToggleDisabled,
    onTogglePin: pins.handleTogglePin,
    onHandleQuickAdd: handleNodeHandleQuickAdd,
    groupingPreview: () => grouping.groupingPreview.value,
  });
  const { edges } = useWorkflowEdges({
    workflow: () => activeWorkflow.value,
    stepExecutions: () => props.stepExecutions ?? [],
  });

  // Prevent the :nodes prop from overwriting Vue Flow's internal drag positions.
  // Vue Flow's per-node dragging flag can briefly flicker during a drag, so also
  // pin the canvas while our local drag session is active.
  const isDragging = computed(() => isLocalDragActive.value || getNodes.value.some(n => n.dragging));
  const displayNodes = shallowRef(nodes.value);
  watch(
    [isDragging, nodes],
    ([dragging, currentNodes]) => {
      if (!dragging) {
        displayNodes.value = currentNodes;
      }
    },
    { immediate: true }
  );

  const draftSync = useDraftSync({
    activeDraft: () => activeDraft.value,
    collabSeq: () => collabSeq.value,
    nodes: () => nodes.value,
    edges: () => edges.value,
    setNodes,
    setEdges,
    isDragging: () => isDragging.value,
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
    emit: emitEditor,
    store,
  });
  const syncSelectionState = () => {
    const selectedNodes =
      getSelectedNodes.value as Parameters<typeof collaboration.handleSelectionChange>[0]['nodes'];

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
    () => getSelectedNodes.value.map(node => node.id).sort().join(','),
    () => {
      syncSelectionState();
    },
    { flush: 'sync', immediate: true }
  );
  const canvas = useCanvasInteraction({
    canEdit: () => canEdit.value,
    project,
    getNodes: () => getNodes.value,
    getSelectedNodes: () => getSelectedNodes.value,
    clearInteraction: collaboration.clearInteraction,
    emitInteraction: collaboration.emitInteraction,
    updateGroupingPreview: grouping.updateGroupingPreview,
    onAddStep: payload => emitEditor('add_step', payload),
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
    emit: emitEditor,
    emitInteraction: collaboration.emitInteraction,
    updateGroupingPreview: grouping.updateGroupingPreview,
    clearGroupingPreview: grouping.clearGroupingPreview,
    getFlowPositionFromEvent: canvas.getFlowPositionFromEvent,
    onNodeDrag,
    onNodeDragStart,
    onNodeDragStop,
    onDraggingChange: dragging => {
      isLocalDragActive.value = dragging;
    },
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
    emit: emitEditor,
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
      syncSelectionState();
    });
  };
  const clipboard = useClipboard({
    getNodes: () => getNodes.value,
    getSelectedNodes: () => getSelectedNodes.value,
    setNodes,
    groupByStepId: () => grouping.groupByStepId.value,
    store,
    emit: emitEditor,
    requestNodeRemoval: nodeInteraction.requestNodeRemoval,
    withSelectionLock: collaboration.withSelectionLock,
  });
  const layoutEngine = useLayoutEngine({
    canEdit: () => canEdit.value,
    getNodes: () => getNodes.value,
    getEdges: () => getEdges.value,
    getSelectedNodes: () => getSelectedNodes.value,
    updateNode,
    emit: emitEditor,
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
    emit: emitEditor,
    isSyncingDraft: () => draftSync.isSyncingDraft.value,
  });
  syncResetRef.value = () => { nodeInteraction.resetPendingNodeRemovals(); edgeInteraction.resetPendingEdgeRemovals(); };
  const nodeLibraryItems = computed<NodeLibraryItem[]>(() => props.nodeLibraryItems ?? []);
  const isAddStepPickerOpen = ref(false);
  const addStepPickerX = ref(0);
  const addStepPickerY = ref(0);
  const pendingHandleQuickAdd = ref<StepHandleQuickAddRequest | null>(null);
  const addStepPickerItems = computed<NodeLibraryItem[]>(() => {
    const quickAddRequest = pendingHandleQuickAdd.value;
    if (!quickAddRequest) return nodeLibraryItems.value;

    if (quickAddRequest.filter.mode === 'output') {
      return nodeLibraryItems.value.filter(item => {
        const isRootNode = item.node_role !== 'subnode';
        return isRootNode && item.step_kind !== 'trigger';
      });
    }

    const acceptedTypeIds = quickAddRequest.filter.accepted_type_ids ?? [];

    return nodeLibraryItems.value.filter(item => {
      if (item.node_role !== 'subnode') return false;
      if (acceptedTypeIds.length === 0) return true;
      return acceptedTypeIds.includes(item.type_id);
    });
  });

  const resolveAddStepSize = (typeId: string) => {
    const selectedItem = nodeLibraryItems.value.find(item => item.type_id === typeId);
    const isSubnode = selectedItem?.node_role === 'subnode';
    const nodeType = isSubnode ? 'subnode' : 'step';

    const measuredNode = getNodes.value.find(
      node => node.type === nodeType && node.dimensions.width > 0 && node.dimensions.height > 0
    );

    if (measuredNode) {
      return {
        width: measuredNode.dimensions.width,
        height: measuredNode.dimensions.height,
      };
    }

    return isSubnode ? SUBNODE_FALLBACK_DIMENSIONS : DEFAULT_NODE_DIMENSIONS;
  };

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

    const quickAddRequest = pendingHandleQuickAdd.value;
    const stepSize = resolveAddStepSize(typeId);
    const resolvedPosition =
      quickAddRequest?.filter.mode === 'output'
        ? {
          x: position.x + QUICK_ADD_OUTPUT_X_OFFSET,
          y: position.y - stepSize.height / 2,
        }
        : position;

    const addStepPayload: {
      type_id: string;
      position: { x: number; y: number };
      group_id?: string;
      auto_connect?: StepHandleQuickAddRequest['autoConnect'];
      step_size?: { width: number; height: number };
    } = {
      type_id: typeId,
      position: resolvedPosition,
      step_size: stepSize,
    };

    const autoConnect = quickAddRequest?.autoConnect;
    if (autoConnect) {
      addStepPayload.auto_connect = autoConnect;
    }

    let targetGroup = findGroupAtPoint(resolvedPosition, getNodes.value);

    if (!targetGroup && quickAddRequest) {
      const fixedStepId =
        quickAddRequest.autoConnect.source_step_id ?? quickAddRequest.autoConnect.target_step_id;
      const fixedGroupId = fixedStepId ? grouping.groupByStepId.value.get(fixedStepId) : undefined;

      if (fixedGroupId) {
        const matchingGroupNode = getNodes.value.find(
          node => node.id === fixedGroupId && node.type === 'group'
        );
        if (matchingGroupNode) {
          targetGroup = matchingGroupNode;
        }
      }
    }

    if (targetGroup) {
      const groupPosition = getAbsoluteNodePosition(targetGroup);
      addStepPayload.position = {
        x: resolvedPosition.x - groupPosition.x,
        y: resolvedPosition.y - groupPosition.y,
      };
      addStepPayload.group_id = targetGroup.id;
    }

    emitEditor('add_step', addStepPayload);
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
    undo: handleUndo,
    redo: handleRedo,
  });
  const actions = useWorkflowActions({
    canEdit: () => canEdit.value,
    emit: emitEditor,
    requestNodeRemoval: nodeInteraction.requestNodeRemoval,
    selectNode: store.selectNode,
  });
  const selectedNode = computed<Node<StepNodeData> | null>(() => {
    const nodeId = store.selectedNodeId;
    if (!nodeId) return null;
    const node = nodes.value.find(n => n.id === nodeId);
    if (!node || !isStepNode(node)) return null;
    return node as Node<StepNodeData>;
  });

  const selectedStepType = computed<StepType | null>(() => {
    if (!selectedNode.value) return null;
    const typeId = selectedNode.value.data?.type_id;
    return (props.stepTypes ?? []).find(st => st.id === typeId) ?? null;
  });

  const isExecutionFailed = computed(() => props.execution?.status === 'failed');
  const isExecutionRunning = computed(() => {
    const status = props.execution?.status;
    return status === 'running' || status === 'pending' || status === 'paused';
  });
  const miniMap = useMiniMapNodeColor();
  const closeContextMenu = () => store.hideContextMenu();
  useLiveEvent<any>('workflow:operation_ack', payload => {
    workflowTrace('server_ack', payload ?? {});

    if (payload?.type !== 'commit_drag_layout' || !optimisticLayout.value) return;

    const seq = Number(payload?.seq);
    if (!Number.isFinite(seq)) return;

    const txnId = typeof payload?.txn_id === 'string' ? payload.txn_id : null;
    if (txnId && optimisticLayout.value.txnId !== txnId) return;

    const nextLayout = { ...optimisticLayout.value, targetSeq: seq };
    optimisticLayout.value = nextLayout;
    maybeClearOptimisticLayout(nextLayout);
  });
  watch(
    [collabSeq, activeDraft, () => optimisticLayout.value?.targetSeq ?? null],
    () => {
      maybeClearOptimisticLayout();
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
    nodes: displayNodes,
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
    selectedNode,
    selectedStepType,
    stepNameById,
    incomingStepIdsByStepId,
    incomingConnectionsByTargetInputByStepId,
    upstreamStepIdsByStepId,
    isExecutionFailed,
    isExecutionRunning,
    miniMapNodeColor: miniMap.miniMapNodeColor,
    otherUserPresences: collaboration.otherUserPresences,
    canvasRef: canvas.canvasRef,
    handlePaneMouseMove: canvas.handlePaneMouseMove,
    handlePaneMouseLeave: canvas.handlePaneMouseLeave,
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
    handlePinOutput: pins.handlePinOutput,
    handleUnpinOutput: pins.handleUnpinOutput,
    selectTraceStep: actions.selectTraceStep,
    expressionPreviews: computed(() => props.expressionPreviews ?? {}),
    nodeLibraryItems,
    addStepPickerItems,
    execution: computed(() => props.execution ?? null),
    stepExecutions: computed(() => props.stepExecutions ?? []),
    editorState: computed(() => props.editorState),
    presences: computed(() => props.presences ?? []),
    currentUserId: computed(() => props.currentUserId),
    workflow: activeWorkflow,
    canUndo,
    canRedo,
    undoTooltip,
    redoTooltip,
    isUndoPending,
  };
}
