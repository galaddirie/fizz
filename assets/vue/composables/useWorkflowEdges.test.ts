import { describe, expect, it } from 'vitest';

import { useWorkflowEdges } from './useWorkflowEdges';
import type { StepExecution, Workflow } from '@/types/workflow';

const workflow: Workflow = {
  id: 'workflow-1',
  name: 'Workflow',
  status: 'draft',
  public: false,
  user_id: 'user-1',
  inserted_at: '2024-01-01T00:00:00Z',
  updated_at: '2024-01-01T00:00:00Z',
  draft: {
    id: 'draft-1',
    workflow_id: 'workflow-1',
    steps: [],
    groups: [],
    triggers: [],
    settings: {},
    connections: [
      {
        id: 'conn-1',
        source_step_id: 'step-a',
        target_step_id: 'step-b',
        source_output: 'main',
        target_input: 'main',
      },
      {
        id: 'conn-2',
        source_step_id: 'step-b',
        target_step_id: 'step-c',
        source_output: 'main',
        target_input: 'secondary',
      },
    ],
  },
};

const runningExecution: StepExecution = {
  id: 'exec-1',
  execution_id: 'run-1',
  step_id: 'step-a',
  step_type_id: 'http',
  status: 'running',
  attempt: 1,
  inserted_at: '2024-01-01T00:00:00Z',
};

describe('useWorkflowEdges', () => {
  it('marks edges animated when their source step is running', () => {
    const { edges } = useWorkflowEdges({
      workflow: () => workflow,
      stepExecutions: () => [runningExecution],
    });

    expect(edges.value).toEqual([
      {
        id: 'conn-1',
        source: 'step-a',
        target: 'step-b',
        sourceHandle: 'main',
        targetHandle: 'main',
        type: 'custom',
        zIndex: 15,
        data: { animated: true },
      },
      {
        id: 'conn-2',
        source: 'step-b',
        target: 'step-c',
        sourceHandle: 'main',
        targetHandle: 'secondary',
        type: 'custom',
        zIndex: 15,
        data: { animated: false },
      },
    ]);
  });
});
