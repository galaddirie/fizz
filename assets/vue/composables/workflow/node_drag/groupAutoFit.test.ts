import { describe, expect, it, vi } from 'vitest';
import type { GraphNode } from '@vue-flow/core';

import type { WorkflowNodeData } from '@/shared/ui/workflow-scene/types';

import { buildCommitDragLayoutPayload } from './commit';
import { applyRealtimeGroupAutoFit, collectDraggingGroupBounds } from './groupAutoFit';
import type { DragSession } from './types';

const createWorkflowNode = (
  overrides: Partial<GraphNode<WorkflowNodeData>>
): GraphNode<WorkflowNodeData> =>
  ({
    id: 'node',
    type: 'step',
    position: { x: 0, y: 0 },
    computedPosition: undefined,
    dimensions: { width: 0, height: 0 },
    style: undefined,
    data: {
      id: 'node',
      type_id: 'http',
      name: 'Node',
      config: {},
      hasInput: true,
      hasOutput: true,
    },
    ...overrides,
  }) as GraphNode<WorkflowNodeData>;

const createDragSession = (overrides: Partial<DragSession> = {}): DragSession => ({
  startPositions: new Map(),
  startAbsolutePositions: new Map(),
  lastPositions: new Map(),
  startGroupBounds: new Map(),
  startStepPositions: new Map(),
  startGroupByStepId: new Map(),
  anchorMouse: { x: 0, y: 0 },
  axisLock: null,
  lockAbsDelta: null,
  recentSamples: [],
  ...overrides,
});

describe('node drag group autofit', () => {
  it('repositions a dragged step relative to the autofit group bounds', () => {
    const groupNode = createWorkflowNode({
      id: 'group-1',
      type: 'group',
      position: { x: 100, y: 100 },
      dimensions: { width: 360, height: 240 },
      style: { width: '360px', height: '240px' },
      data: {
        id: 'group-1',
        name: 'Group',
        step_ids: ['step-1'],
        collapsed: false,
      },
    });
    const stepNode = createWorkflowNode({
      id: 'step-1',
      position: { x: 24, y: 64 },
      parentNode: 'group-1',
      data: {
        id: 'step-1',
        type_id: 'http',
        name: 'Step',
        config: {},
        hasInput: true,
        hasOutput: true,
      },
    });
    const session = createDragSession({
      startGroupBounds: new Map([
        ['group-1', { x: 100, y: 100, width: 360, height: 240 }],
      ]),
      lastPositions: new Map([['step-1', { x: 72, y: 64 }]]),
    });
    const updateNode = vi.fn();

    const result = applyRealtimeGroupAutoFit({
      draggingStepPositions: { 'step-1': { x: 72, y: 64 } },
      session,
      currentGroupByStepId: new Map([['step-1', 'group-1']]),
      allNodes: [groupNode, stepNode],
      updateNode,
    });

    expect(result.groupBoundsById['group-1']).toEqual({
      x: 148,
      y: 100,
      width: 360,
      height: 240,
    });
    expect(result.stepPositions['step-1']).toEqual({ x: 24, y: 64 });
    expect(session.lastPositions.get('step-1')).toEqual({ x: 24, y: 64 });
    expect(updateNode).toHaveBeenCalledWith('group-1', {
      position: { x: 148, y: 100 },
      style: { width: '360px', height: '240px' },
    });
    expect(updateNode).toHaveBeenCalledWith('step-1', {
      position: { x: 24, y: 64 },
    });
  });

  it('collects only dragged group bounds for collaboration payloads', () => {
    const groupNode = createWorkflowNode({
      id: 'group-1',
      type: 'group',
      position: { x: 100, y: 100 },
      dimensions: { width: 360, height: 240 },
      style: { width: '360px', height: '240px' },
      data: {
        id: 'group-1',
        name: 'Group',
        step_ids: [],
        collapsed: false,
      },
    });
    const stepNode = createWorkflowNode({
      id: 'step-1',
      position: { x: 24, y: 64 },
      parentNode: 'group-1',
      data: {
        id: 'step-1',
        type_id: 'http',
        name: 'Step',
        config: {},
        hasInput: true,
        hasOutput: true,
      },
    });

    expect(
      collectDraggingGroupBounds(
        [groupNode, stepNode],
        new Map([
          ['group-1', groupNode],
          ['step-1', stepNode],
        ])
      )
    ).toEqual({
      'group-1': { x: 100, y: 100, width: 360, height: 240 },
    });
  });

  it('builds a drag commit payload when a step is dropped into a group', () => {
    const groupNode = createWorkflowNode({
      id: 'group-1',
      type: 'group',
      position: { x: 100, y: 100 },
      dimensions: { width: 360, height: 240 },
      style: { width: '360px', height: '240px' },
      data: {
        id: 'group-1',
        name: 'Group',
        step_ids: [],
        collapsed: false,
      },
    });
    const stepNode = createWorkflowNode({
      id: 'step-1',
      position: { x: 140, y: 160 },
      data: {
        id: 'step-1',
        type_id: 'http',
        name: 'Step',
        config: {},
        hasInput: true,
        hasOutput: true,
      },
    });
    const session = createDragSession({
      startGroupBounds: new Map([
        ['group-1', { x: 100, y: 100, width: 360, height: 240 }],
      ]),
      startStepPositions: new Map([['step-1', { x: 140, y: 160 }]]),
      startGroupByStepId: new Map(),
    });

    const payload = buildCommitDragLayoutPayload({
      draggedNodes: [stepNode],
      flowPosition: { x: 120, y: 120 },
      ungroupModifierPressed: false,
      allNodes: [groupNode, stepNode],
      session,
      currentGroupByStepId: new Map(),
      collabSeq: 7,
    });

    expect(payload).not.toBeNull();
    expect(payload?.base_seq).toBe(7);
    expect(payload?.group_id_by_step_id).toEqual({ 'step-1': 'group-1' });
    expect(payload?.step_positions).toEqual({ 'step-1': { x: 24, y: 64 } });
    expect(payload?.groups).toEqual([
      {
        group_id: 'group-1',
        position: { x: 116, y: 96, width: 360, height: 240 },
      },
    ]);
  });
});
