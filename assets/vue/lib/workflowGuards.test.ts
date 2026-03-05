import { describe, expect, it } from 'vitest';
import type { Node } from '@vue-flow/core';

import { isGroupNode, isStepNode } from './workflowGuards';
import type { WorkflowNodeData } from '@/shared/ui/workflow-scene/types';

const createNode = (type: string) =>
  ({
    id: `${type}-1`,
    type,
    position: { x: 0, y: 0 },
    data: {
      id: `${type}-1`,
      name: type,
      type_id: type,
      config: {},
      hasInput: true,
      hasOutput: true,
      step_ids: [],
      collapsed: false,
      output_step_id: '',
      position: { x: 0, y: 0, width: 100, height: 80 },
    },
  }) as unknown as Node<WorkflowNodeData>;

describe('workflowGuards', () => {
  it('identifies group nodes', () => {
    const groupNode = createNode('group');

    expect(isGroupNode(groupNode)).toBe(true);
    expect(isStepNode(groupNode)).toBe(false);
  });

  it('identifies step and subnode nodes', () => {
    const stepNode = createNode('step');
    const subnode = createNode('subnode');

    expect(isStepNode(stepNode)).toBe(true);
    expect(isStepNode(subnode)).toBe(true);
    expect(isGroupNode(stepNode)).toBe(false);
  });
});
