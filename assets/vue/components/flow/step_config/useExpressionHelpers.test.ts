import { computed, ref } from 'vue';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import type { Node } from '@vue-flow/core';

import { useExpressionHelpers } from './useExpressionHelpers';
import type { StepNodeData } from '@/types/workflow';

const createNode = (id = 'step-current', name = 'Current Step') =>
  ({
    id,
    data: {
      id,
      type_id: 'http',
      name,
      config: {},
      hasInput: true,
      hasOutput: true,
    },
  }) as Node<StepNodeData>;

describe('useExpressionHelpers', () => {
  beforeEach(() => {
    Object.defineProperty(window.navigator, 'clipboard', {
      configurable: true,
      value: { writeText: vi.fn() },
    });
  });

  it('formats expressions for workflow sections and labels multi-input array entries', () => {
    const editName = ref('Renamed Step');

    const helpers = useExpressionHelpers({
      node: () => createNode(),
      stepNameById: () => ({ 'step-upstream': 'Fetch User' }),
      editName,
      currentInputState: computed(() => ({
        status: 'available',
        reason: null,
        data: [{ value: 1 }, { value: 2 }],
      })),
      directUpstreamStepIds: computed(() => ['step-upstream', 'step-other']),
      inputIndexLabels: computed(() => ['Fetch User', 'Normalize']),
    });

    expect(helpers.getExpressionFor('json', '0')).toBe('{{ json[0] }}');
    expect(helpers.getExpressionFor('steps', 'step-upstream')).toBe(
      '{{ steps["fetch_user"].json }}',
    );
    expect(helpers.getExpressionFor('steps', 'step-current')).toBe(
      '{{ steps["renamed_step"].json }}',
    );
    expect(helpers.formatSectionKey('json', '1')).toBe('1 - Normalize');
    expect(helpers.formatSectionKey('variables', 'token')).toBe('token');
  });

  it('copies generated expressions to the clipboard', () => {
    const writeText = vi.fn();
    Object.defineProperty(window.navigator, 'clipboard', {
      configurable: true,
      value: { writeText },
    });

    const helpers = useExpressionHelpers({
      node: () => createNode(),
      stepNameById: () => ({}),
      editName: ref('Current Step'),
      currentInputState: computed(() => ({
        status: 'available',
        reason: null,
        data: {},
      })),
      directUpstreamStepIds: computed(() => ['step-upstream']),
      inputIndexLabels: computed(() => ['Fetch User']),
    });

    helpers.copyExpression('trigger', 'token');

    expect(writeText).toHaveBeenCalledWith('{{ trigger.token }}');
  });
});
