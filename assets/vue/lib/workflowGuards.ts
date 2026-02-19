import type { GraphNode, Node } from '@vue-flow/core';

import type { GroupNodeData, StepNodeData, WorkflowNodeData } from '@/types/workflow';

export const isGroupNode = (
  node: GraphNode<WorkflowNodeData> | Node<WorkflowNodeData>
): node is GraphNode<GroupNodeData> => node.type === 'group';

export const isStepNode = (
  node: GraphNode<WorkflowNodeData> | Node<WorkflowNodeData>
): node is GraphNode<StepNodeData> => node.type === 'step';
