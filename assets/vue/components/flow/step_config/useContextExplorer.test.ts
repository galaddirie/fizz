import { computed } from 'vue';
import { describe, expect, it } from 'vitest';
import type { Node } from '@vue-flow/core';

import { useContextExplorer } from './useContextExplorer';
import type { StepNodeData } from '@/shared/ui/workflow-scene/types';
import type { Execution, StepExecution } from '@/types/workflow';

const createNode = (id = 'step-current') =>
  ({
    id,
    data: {
      id,
      type_id: 'http',
      name: 'Current Step',
      config: {},
      hasInput: true,
      hasOutput: true,
    },
  }) as Node<StepNodeData>;

const createStepExecution = (overrides: Partial<StepExecution> = {}): StepExecution => ({
  id: 'exec-1',
  execution_id: 'run-1',
  step_id: 'step-upstream',
  step_type_id: 'http',
  status: 'completed',
  attempt: 1,
  inserted_at: '2024-01-01T00:00:00Z',
  ...overrides,
});

describe('useContextExplorer', () => {
  it('builds context from current input, trigger data, request metadata, and upstream step outputs', () => {
    const execution: Execution = {
      id: 'run-1',
      workflow_id: 'workflow-1',
      status: 'completed',
      execution_type: 'production',
      trigger: { type: 'manual', data: { value: { trigger: true } } },
      metadata: {
        variables: { api_key: 'secret' },
        extras: {
          request: { path: '/hooks/run' },
        },
      },
      inserted_at: '2024-01-01T00:00:00Z',
      updated_at: '2024-01-01T00:00:00Z',
    };

    const explorer = useContextExplorer({
      node: () => createNode(),
      execution: () => execution,
      stepExecutions: () => [
        createStepExecution({ output_data: { value: { id: 42 } } }),
        createStepExecution({
          id: 'exec-2',
          step_id: 'step-ignored',
          output_data: { value: { ignored: true } },
        }),
      ],
      stepNameById: () => ({ 'step-upstream': 'Fetch User' }),
      upstreamStepIds: () => ({ 'step-current': ['step-upstream'] }),
      currentInputState: computed(() => ({
        status: 'available',
        reason: null,
        data: 'input payload',
      })),
    });

    expect(explorer.contextData.value).toEqual({
      json: 'input payload',
      trigger: { value: { trigger: true } },
      variables: { api_key: 'secret' },
      request: { path: '/hooks/run' },
      steps: {
        'Fetch User': {
          json: { id: 42 },
        },
      },
    });

    expect(explorer.explorerData.value).toEqual([
      {
        id: 'json',
        label: 'Input Data',
        icon: 'ArrowRightOnRectangleIcon',
        data: { json: 'input payload' },
      },
      {
        id: 'trigger',
        label: 'Trigger Data',
        icon: 'BoltIcon',
        data: { value: { trigger: true } },
      },
      {
        id: 'steps',
        label: 'Upstream Steps',
        icon: 'CpuChipIcon',
        data: {
          'Fetch User': {
            json: { id: 42 },
          },
        },
      },
      {
        id: 'variables',
        label: 'Workflow Variables',
        icon: 'VariableIcon',
        data: { api_key: 'secret' },
      },
      {
        id: 'request',
        label: 'Request Metadata',
        icon: 'GlobeAltIcon',
        data: { path: '/hooks/run' },
      },
    ]);
  });
});
