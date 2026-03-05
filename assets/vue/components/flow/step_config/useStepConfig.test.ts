import { reactive } from 'vue';
import { describe, expect, it, vi } from 'vitest';
import type { Node } from '@vue-flow/core';

import { useStepConfig } from './useStepConfig';
import type { StepNodeData } from '@/shared/ui/workflow-scene/types';

const createNode = (config: Record<string, unknown>) =>
  ({
    id: 'step-current',
    data: {
      id: 'step-current',
      type_id: 'http',
      name: 'Current Step',
      config,
      hasInput: true,
      hasOutput: true,
    },
  }) as Node<StepNodeData>;

describe('useStepConfig', () => {
  it('tracks in-place nested config edits as unsaved changes', () => {
    const state = useStepConfig(
      reactive({
        node: createNode({
          settings: {
            retries: 1,
            headers: { authorization: 'token' },
          },
        }),
        isOpen: true,
      }),
      vi.fn(),
    );

    const settings = state.fieldValues.value.settings as {
      retries: number;
      headers: { authorization: string };
    };
    settings.headers.authorization = 'updated-token';

    expect(state.hasUnsavedChanges.value).toBe(true);
    expect(state.originalValues.value.settings).toEqual({
      retries: 1,
      headers: { authorization: 'token' },
    });
  });
});
