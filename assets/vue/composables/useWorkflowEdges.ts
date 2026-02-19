import { computed } from 'vue';
import type { Edge } from '@vue-flow/core';

import type { Workflow, StepExecution, EdgeData } from '@/types/workflow';

interface UseWorkflowEdgesOptions {
  workflow: () => Workflow;
  stepExecutions: () => StepExecution[];
}

export function useWorkflowEdges(options: UseWorkflowEdgesOptions) {
  const runningStepIds = computed(() => {
    const ids = new Set<string>();
    for (const execution of options.stepExecutions()) {
      if (execution.status === 'running') {
        ids.add(execution.step_id);
      }
    }
    return ids;
  });

  const edges = computed<Edge<EdgeData>[]>(() => {
    const connections = options.workflow().draft?.connections || [];
    const runningIds = runningStepIds.value;

    return connections.map(conn => ({
      id: conn.id,
      source: conn.source_step_id,
      target: conn.target_step_id,
      sourceHandle: conn.source_output,
      targetHandle: conn.target_input,
      type: 'custom',
      zIndex: 15,
      data: { animated: runningIds.has(conn.source_step_id) } satisfies EdgeData,
    }));
  });

  return { edges };
}
