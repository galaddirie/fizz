import { computed, markRaw, ref } from "vue";
import type { VNodeRef } from "vue";
import { VueFlow, useVueFlow } from "@vue-flow/core";
import type { Node, NodeMouseEvent } from "@vue-flow/core";

import WorkflowStepNode from "@/components/flow/Node.vue";
import WorkflowSubNode from "@/components/flow/SubNode.vue";
import GroupNode from "@/components/flow/GroupNode.vue";
import { useWorkflowEdges } from "@/composables/useWorkflowEdges";
import { useWorkflowGraph } from "@/composables/useWorkflowGraph";
import { useWorkflowNodes } from "@/composables/useWorkflowNodes";
import { useDraftSync } from "@/composables/workflow/useDraftSync";
import { useMiniMapNodeColor } from "@/composables/workflow/useMiniMapNodeColor";
import type { RevisionViewerViewProps } from "@/features/revision-viewer/contracts/revisionViewer";
import { isStepNode } from "@/lib/workflowGuards";
import { workflowEdgeTypes } from "@/shared/ui/workflow-scene/edgeTypes";
import type { WorkflowNodeData } from "@/shared/ui/workflow-scene/types";

export function useRevisionViewer(props: RevisionViewerViewProps) {
  const { setNodes, setEdges, viewport } = useVueFlow();
  const canvasRef = ref<HTMLElement | null>(null);
  const vueFlowRef = ref<InstanceType<typeof VueFlow> | null>(null);
  const selectedNodeId = ref<string | null>(null);
  const isInspectorOpen = ref(false);

  const activeWorkflow = computed(() => ({
    ...props.document.workflow,
    draft: props.document.draft,
  }));

  const { nodes } = useWorkflowNodes({
    workflow: () => activeWorkflow.value,
    stepTypes: () => props.document.stepTypes,
    stepExecutions: () => [],
    editorState: () => props.document.editorState,
    presences: () => [],
    currentUserId: () => undefined,
    canEdit: () => false,
  });

  const { edges } = useWorkflowEdges({
    workflow: () => activeWorkflow.value,
    stepExecutions: () => [],
  });

  const draftSync = useDraftSync({
    activeDraft: () => props.document.draft,
    nodes: () => nodes.value,
    edges: () => edges.value,
    setNodes,
    setEdges,
  });

  const { stepNameById, incomingStepIdsByStepId, upstreamStepIdsByStepId } =
    useWorkflowGraph(() => activeWorkflow.value);
  const { miniMapNodeColor } = useMiniMapNodeColor();

  const nodeTypes = {
    step: markRaw(WorkflowStepNode),
    subnode: markRaw(WorkflowSubNode),
    group: markRaw(GroupNode),
  };
  const edgeTypes = workflowEdgeTypes;

  const workflowName = computed(() => props.document.workflow.name);
  const revisionLabel = computed(() => props.history.revision.label);
  const canApply = computed(() => props.history.revision.kind !== "current");
  const isCurrentDraft = computed(
    () => props.history.revision.kind === "current"
  );
  const workflowUpdatedAt = computed(() => props.document.workflow.updated_at);
  const undoStack = computed(() => props.history.undoStack);
  const versions = computed(() => props.history.versions);

  const selectedNode = computed(() => {
    if (!selectedNodeId.value) return null;
    const node = nodes.value.find((node) => node.id === selectedNodeId.value);
    return node && isStepNode(node) ? node : null;
  });

  const selectedStepType = computed(() => {
    if (!selectedNode.value) return null;
    const typeId = selectedNode.value.data?.type_id;
    return (
      props.document.stepTypes.find((stepType) => stepType.id === typeId) ??
      null
    );
  });

  const handleNodeClick = (event: NodeMouseEvent) => {
    if (isStepNode(event.node)) {
      selectedNodeId.value = event.node.id;
    }
  };

  const handleNodeDoubleClick = (event: NodeMouseEvent) => {
    if (isStepNode(event.node)) {
      selectedNodeId.value = event.node.id;
      isInspectorOpen.value = true;
    }
  };

  const handleSelectionChange = ({
    nodes: selected,
  }: {
    nodes: Node<WorkflowNodeData>[];
  }) => {
    const stepNode = selected.find((node) => isStepNode(node));
    selectedNodeId.value = stepNode?.id ?? null;
  };

  const closeInspector = () => {
    isInspectorOpen.value = false;
  };

  const isSelectedUndo = (entry: { depth: number }) => {
    return (
      props.history.revision.kind === "undo" &&
      props.history.revision.depth === entry.depth
    );
  };

  const isSelectedVersion = (version: { id: string }) => {
    return (
      props.history.revision.kind === "version" &&
      props.history.revision.id === version.id
    );
  };

  const formatRevisionTimestamp = (value?: string | null) => {
    if (!value) return "Unknown";
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return value;
    return date.toLocaleString();
  };

  const setCanvasRef: VNodeRef = (element) => {
    if (typeof HTMLElement !== "undefined" && element instanceof HTMLElement) {
      canvasRef.value = element;
      return;
    }
    canvasRef.value = null;
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
