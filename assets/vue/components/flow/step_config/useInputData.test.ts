import { computed, ref } from 'vue';
import { describe, expect, it, vi } from 'vitest';
import type { Node } from '@vue-flow/core';

import { useInputData } from './useInputData';
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

const createExecution = (overrides: Partial<Execution> = {}): Execution => ({
  id: 'run-1',
  workflow_id: 'workflow-1',
  status: 'completed',
  execution_type: 'production',
  trigger: { type: 'manual', data: { value: { hello: 'world' } } },
  inserted_at: '2024-01-01T00:00:00Z',
  updated_at: '2024-01-01T00:00:00Z',
  ...overrides,
});

const createStepExecution = (overrides: Partial<StepExecution> = {}): StepExecution => ({
  id: 'step-exec-1',
  execution_id: 'run-1',
  step_id: 'step-upstream',
  step_type_id: 'http',
  status: 'completed',
  attempt: 1,
  inserted_at: '2024-01-01T00:00:00Z',
  ...overrides,
});

describe('useInputData', () => {
  it('surfaces trigger data when a trigger step has no upstream nodes', () => {
    const emit = vi.fn();

    const inputData = useInputData({
      node: () => createNode(),
      execution: () => createExecution(),
      canEdit: computed(() => true),
      resolveLatestExecution: () => null,
      selectedItemIndex: ref(null),
      isTriggerStep: computed(() => true),
      directUpstreamStepIds: computed(() => []),
      emit,
    });

    expect(inputData.currentInputState.value).toEqual({
      status: 'available',
      reason: null,
      data: { hello: 'world' },
    });
    expect(inputData.runInputLabel.value).toBe('Run to this step');
  });

  it('returns upstream output for a completed single upstream step', () => {
    const latestExecution = createStepExecution({
      output_data: { value: { id: 7 } },
    });

    const inputData = useInputData({
      node: () => createNode(),
      execution: () => createExecution(),
      canEdit: computed(() => true),
      resolveLatestExecution: () => latestExecution,
      selectedItemIndex: ref(0),
      isTriggerStep: computed(() => false),
      directUpstreamStepIds: computed(() => ['step-upstream']),
      emit: vi.fn(),
    });

    expect(inputData.currentInputState.value).toEqual({
      status: 'available',
      reason: null,
      data: { id: 7 },
    });
    expect(inputData.currentInputEmptyState.value.title).toBe('No input data yet');
  });

  it('marks failed upstream executions as missing data', () => {
    const inputData = useInputData({
      node: () => createNode(),
      execution: () => createExecution(),
      canEdit: computed(() => true),
      resolveLatestExecution: () => createStepExecution({ status: 'failed' }),
      selectedItemIndex: ref(null),
      isTriggerStep: computed(() => false),
      directUpstreamStepIds: computed(() => ['step-upstream']),
      emit: vi.fn(),
    });

    expect(inputData.currentInputState.value).toEqual({
      status: 'missing',
      reason: 'failed',
      data: null,
    });
    expect(inputData.currentInputEmptyState.value.title).toBe('Upstream step failed');
  });

  it('emits run_node only when editing is allowed and a node exists', () => {
    const emit = vi.fn();

    const inputData = useInputData({
      node: () => createNode('step-run'),
      execution: () => createExecution(),
      canEdit: computed(() => true),
      resolveLatestExecution: () => null,
      selectedItemIndex: ref(null),
      isTriggerStep: computed(() => false),
      directUpstreamStepIds: computed(() => ['step-upstream']),
      emit,
    });

    inputData.runInput();

    expect(emit).toHaveBeenCalledWith('run_node', 'step-run');
  });
});
