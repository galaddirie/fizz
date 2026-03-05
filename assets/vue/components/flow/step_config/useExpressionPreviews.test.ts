import { describe, expect, it } from 'vitest';
import type { Node } from '@vue-flow/core';

import { useExpressionPreviews } from './useExpressionPreviews';
import type { StepNodeData } from '@/types/workflow';

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

describe('useExpressionPreviews', () => {
  it('derives preview keys and values from the current node', () => {
    const previews = useExpressionPreviews({
      node: () => createNode(),
      expressionPreviews: () => ({
        'step-current:title': 'Hello world',
      }),
    });

    expect(previews.previewKeyFor('title')).toBe('step-current:title');
    expect(previews.hasPreviewFor('title')).toBe(true);
    expect(previews.previewValueFor('title')).toBe('Hello world');
    expect(previews.hasPreviewFor('missing')).toBe(false);
  });

  it('recognizes error payloads and formats preview values as text', () => {
    const previews = useExpressionPreviews({
      node: () => createNode(),
      expressionPreviews: () => ({}),
    });

    expect(
      previews.previewIsError({
        type: 'parse_error',
        text: 'unexpected token',
      }),
    ).toBe(true);
    expect(previews.previewToText({ ok: true })).toBe('{\n  "ok": true\n}');
    expect(previews.previewToText(undefined)).toBe('undefined');
    expect(previews.previewToText(null)).toBe('null');
  });
});
