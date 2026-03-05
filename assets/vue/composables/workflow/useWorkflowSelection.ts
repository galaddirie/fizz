import { computed } from 'vue';
import type { Node } from '@vue-flow/core';

import { isStepNode } from '@/lib/workflowGuards';
import type {
  StepNodeData,
  WorkflowNodeData,
} from '@/shared/ui/workflow-scene/types';
import type { StepType } from '@/types/workflow';

interface UseWorkflowSelectionOptions {
  nodes: () => Node<WorkflowNodeData>[];
  selectedNodeId: () => string | null;
  stepTypes: () => StepType[];
}

export function useWorkflowSelection(options: UseWorkflowSelectionOptions) {
  const selectedNode = computed<Node<StepNodeData> | null>(() => {
    const nodeId = options.selectedNodeId();
    if (!nodeId) return null;
    const node = options.nodes().find(n => n.id === nodeId);
    if (!node || !isStepNode(node)) return null;
    return node as Node<StepNodeData>;
  });

  const selectedStepType = computed<StepType | null>(() => {
    if (!selectedNode.value) return null;
    const typeId = selectedNode.value.data?.type_id;
    return options.stepTypes().find(st => st.id === typeId) ?? null;
  });

  return {
    selectedNode,
    selectedStepType,
  };
}
