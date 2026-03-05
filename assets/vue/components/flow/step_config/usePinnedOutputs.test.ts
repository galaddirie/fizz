import { computed } from 'vue';
import { describe, expect, it, vi } from 'vitest';
import type { Node } from '@vue-flow/core';

import { usePinnedOutputs } from './usePinnedOutputs';
import type { EditorState, StepExecution, StepNodeData } from '@/types/workflow';

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

const createExecution = (overrides: Partial<StepExecution> = {}): StepExecution => ({
  id: 'exec-1',
  execution_id: 'run-1',
  step_id: 'step-current',
  step_type_id: 'http',
  status: 'completed',
  output_data: { value: { ok: true } },
  item_index: 2,
  attempt: 1,
  inserted_at: '2024-01-01T00:00:00Z',
  ...overrides,
});

describe('usePinnedOutputs', () => {
  it('derives pin state from editor state and emits pin/unpin payloads', () => {
    const emit = vi.fn();
    const editorState: EditorState = {
      workflow_id: 'workflow-1',
      pinned_outputs: {
        'step-current': { cached: true },
      },
    };

    const pinnedOutputs = usePinnedOutputs({
      node: () => createNode(),
      editorState: () => editorState,
      canEdit: computed(() => true),
      activeStepExecution: computed(() => createExecution()),
      emit,
    });

    expect(pinnedOutputs.hasPinnedOutput.value).toBe(true);
    expect(pinnedOutputs.pinnedOutput.value).toEqual({ cached: true });
    expect(pinnedOutputs.canPinOutput.value).toBe(true);
    expect(pinnedOutputs.pinButtonLabel.value).toBe('Update Pin');

    pinnedOutputs.pinOutput();
    pinnedOutputs.unpinOutput();

    expect(emit).toHaveBeenNthCalledWith(1, 'pin_output', {
      step_id: 'step-current',
      output_data: { value: { ok: true } },
      item_index: 2,
    });
    expect(emit).toHaveBeenNthCalledWith(2, 'unpin_output', { step_id: 'step-current' });
  });

  it('refuses to pin when editing is disabled or execution is incomplete', () => {
    const emit = vi.fn();

    const pinnedOutputs = usePinnedOutputs({
      node: () => createNode(),
      editorState: () => ({ workflow_id: 'workflow-1' }),
      canEdit: computed(() => false),
      activeStepExecution: computed(() => createExecution({ status: 'running' })),
      emit,
    });

    pinnedOutputs.pinOutput();

    expect(emit).not.toHaveBeenCalled();
    expect(pinnedOutputs.canPinOutput.value).toBe(false);
  });
});
