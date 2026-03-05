import { describe, expect, it } from 'vitest';

import { useWorkflowGraph } from './useWorkflowGraph';
import type { Workflow } from '@/types/workflow';

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
    groups: [],
    triggers: [],
    settings: {},
    steps: [
      { id: 'trigger', type_id: 'trigger', name: 'Trigger', config: {}, position: { x: 0, y: 0 } },
      { id: 'fetch', type_id: 'http', name: 'Fetch User', config: {}, position: { x: 0, y: 0 } },
      { id: 'transform', type_id: 'code', name: 'Transform', config: {}, position: { x: 0, y: 0 } },
      { id: 'notify', type_id: 'email', name: 'Notify', config: {}, position: { x: 0, y: 0 } },
    ],
    connections: [
      {
        id: 'conn-1',
        source_step_id: 'trigger',
        target_step_id: 'fetch',
        source_output: 'main',
        target_input: 'main',
      },
      {
        id: 'conn-2',
        source_step_id: 'fetch',
        target_step_id: 'transform',
        source_output: 'main',
        target_input: 'main',
      },
      {
        id: 'conn-3',
        source_step_id: 'fetch',
        target_step_id: 'notify',
        source_output: 'main',
        target_input: 'recipient',
      },
      {
        id: 'conn-4',
        source_step_id: 'transform',
        target_step_id: 'notify',
        source_output: 'main',
        target_input: 'body',
      },
    ],
  },
};

describe('useWorkflowGraph', () => {
  it('derives ordered workflow graph lookup tables', () => {
    const graph = useWorkflowGraph(() => workflow);

    expect(graph.stepNameById.value).toEqual({
      trigger: 'Trigger',
      fetch: 'Fetch User',
      transform: 'Transform',
      notify: 'Notify',
    });
    expect(graph.incomingStepIdsByStepId.value).toEqual({
      trigger: [],
      fetch: ['trigger'],
      transform: ['fetch'],
      notify: ['fetch', 'transform'],
    });
    expect(graph.upstreamStepIdsByStepId.value).toEqual({
      trigger: [],
      fetch: ['trigger'],
      transform: ['fetch', 'trigger'],
      notify: ['fetch', 'trigger', 'transform'],
    });
    expect(graph.incomingConnectionsByTargetInputByStepId.value).toEqual({
      trigger: {},
      fetch: { main: ['trigger'] },
      transform: { main: ['fetch'] },
      notify: {
        recipient: ['fetch'],
        body: ['transform'],
      },
    });
  });
});
