import { computed } from 'vue';

import type { Execution } from '@/types/workflow';

interface UseWorkflowExecutionStateOptions {
  execution: () => Execution | null | undefined;
}

export function useWorkflowExecutionState(options: UseWorkflowExecutionStateOptions) {
  const isExecutionFailed = computed(() => options.execution()?.status === 'failed');

  const isExecutionRunning = computed(() => {
    const status = options.execution()?.status;
    return status === 'running' || status === 'pending';
  });

  return {
    isExecutionFailed,
    isExecutionRunning,
  };
}
