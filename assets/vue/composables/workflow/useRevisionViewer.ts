import { computed, markRaw, ref } from 'vue';
import type { VNodeRef } from 'vue';
import { VueFlow, useVueFlow } from '@vue-flow/core';
import type { NodeMouseEvent, Node, Edge } from '@vue-flow/core';

import WorkflowStepNode from '@/components/flow/Node.vue';
import GroupNode from '@/components/flow/GroupNode.vue';
import CustomEdge from '@/components/flow/Edge.vue';
import { useWorkflowEdges } from '@/composables/useWorkflowEdges';
import { useWorkflowGraph } from '@/composables/useWorkflowGraph';
import { useWorkflowNodes } from '@/composables/useWorkflowNodes';
import { useDraftSync } from '@/composables/workflow/useDraftSync';
import { useMiniMapNodeColor } from '@/composables/workflow/useMiniMapNodeColor';
import type { RevisionViewerProps } from '@/types/revisionViewer';
import type { EdgeData, WorkflowNodeData } from '@/types/workflow';

export function useRevisionViewer(props: RevisionViewerProps) {
  const { setNodes, setEdges, viewport } = useVueFlow();
  const canvasRef = ref<HTMLElement | null>(null);
  const vueFlowRef = ref<InstanceType<typeof VueFlow> | null>(null);
  const selectedNodeId = ref<string | null>(null);
  const isInspectorOpen = ref(false);

  const activeWorkflow = computed(() => ({
    ...props.workflow,
    draft: props.draft,
  }));

  const { nodes } = useWorkflowNodes({
    workflow: () => activeWorkflow.value,
    stepTypes: () => props.stepTypes,
    stepExecutions: () => [],
    editorState: () => props.editorState,
    presences: () => [],
    currentUserId: () => undefined,
    canEdit: () => false,
  });

  const { edges } = useWorkflowEdges({
    workflow: () => activeWorkflow.value,
    stepExecutions: () => [],
  });

  const draftSync = useDraftSync({
    activeDraft: () => props.draft,
    nodes: () => nodes.value as Node<WorkflowNodeData>[],
    edges: () => edges.value as Edge<EdgeData>[],
    setNodes,
    setEdges,
  });

  const { stepNameById, incomingStepIdsByStepId, upstreamStepIdsByStepId } = useWorkflowGraph(
    () => activeWorkflow.value
  );
  const { miniMapNodeColor } = useMiniMapNodeColor();

  const nodeTypes = { step: markRaw(WorkflowStepNode), group: markRaw(GroupNode) };
  const edgeTypes = { custom: markRaw(CustomEdge as any) };

  const workflowName = computed(() => props.workflow.name);
  const revisionLabel = computed(() => props.revision.label);
  const canApply = computed(() => props.revision.kind !== 'current');
  const isCurrentDraft = computed(() => props.revision.kind === 'current');
  const workflowUpdatedAt = computed(() => props.workflow.updated_at);
  const undoStack = computed(() => props.undoStack);
  const versions = computed(() => props.versions);

  const selectedNode = computed(() => {
    if (!selectedNodeId.value) return null;
    return nodes.value.find(node => node.id === selectedNodeId.value && node.type === 'step') ?? null;
  });

  const selectedStepType = computed(() => {
    if (!selectedNode.value) return null;
    const typeId = selectedNode.value.data?.type_id;
    return props.stepTypes.find(stepType => stepType.id === typeId) ?? null;
  });

  const handleNodeClick = (event: NodeMouseEvent) => {
    if (event.node.type === 'step') {
      selectedNodeId.value = event.node.id;
    }
  };

  const handleNodeDoubleClick = (event: NodeMouseEvent) => {
    if (event.node.type === 'step') {
      selectedNodeId.value = event.node.id;
      isInspectorOpen.value = true;
    }
  };

  const handleSelectionChange = ({ nodes: selected }: { nodes: Node<WorkflowNodeData>[] }) => {
    const stepNode = selected.find(node => node.type === 'step');
    selectedNodeId.value = stepNode?.id ?? null;
  };

  const closeInspector = () => {
    isInspectorOpen.value = false;
  };

  const isSelectedUndo = (entry: { depth: number }) => {
    return props.revision.kind === 'undo' && props.revision.depth === entry.depth;
  };

  const isSelectedVersion = (version: { id: string }) => {
    return props.revision.kind === 'version' && props.revision.id === version.id;
  };

  const formatRevisionTimestamp = (value?: string | null) => {
    if (!value) return 'Unknown';
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return value;
    return date.toLocaleString();
  };

  const setCanvasRef: VNodeRef = element => {
    if (typeof HTMLElement !== 'undefined' && element instanceof HTMLElement) {
      canvasRef.value = element;
      return;
    }
    canvasRef.value = null;
  };

  const setVueFlowRef: VNodeRef = instance => {
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

  return {
    nodes,
    edges,
    nodeTypes,
    edgeTypes,
    viewport,
    isMounted: draftSync.isMounted,
    workflowName,
    revisionLabel,
    canApply,
    isCurrentDraft,
    workflowUpdatedAt,
    undoStack,
    versions,
    selectedNode,
    selectedStepType,
    isInspectorOpen,
    stepNameById,
    incomingStepIdsByStepId,
    upstreamStepIdsByStepId,
    handleNodeClick,
    handleNodeDoubleClick,
    handleSelectionChange,
    closeInspector,
    isSelectedUndo,
    isSelectedVersion,
    formatRevisionTimestamp,
    setCanvasRef,
    setVueFlowRef,
    miniMapNodeColor,
  };
}
