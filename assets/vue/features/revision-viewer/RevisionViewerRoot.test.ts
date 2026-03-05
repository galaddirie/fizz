import { mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';

import RevisionViewerRoot from './RevisionViewerRoot.vue';

vi.mock('./controllers/useRevisionViewerRoot', () => ({
  useRevisionViewerRoot: (_props: unknown, emitAction: (action: unknown) => void) => ({
    viewer: {
      canApply: true,
      workflowName: 'Workflow',
      revisionLabel: 'Revision label',
      isInspectorOpen: false,
      selectedNode: null,
      selectedStepType: null,
      stepNameById: {},
      incomingStepIdsByStepId: {},
      upstreamStepIdsByStepId: {},
      closeInspector: vi.fn(),
      workflowUpdatedAt: '2024-01-01T00:00:00Z',
      isCurrentDraft: false,
      undoStack: [],
      versions: [],
      isSelectedUndo: vi.fn().mockReturnValue(false),
      isSelectedVersion: vi.fn().mockReturnValue(false),
      formatRevisionTimestamp: vi.fn().mockImplementation(value => value ?? 'Unknown'),
    },
    sceneModel: {
      nodes: [],
      edges: [],
      nodeTypes: {},
      edgeTypes: {},
      snapEnabled: false,
      gridSize: 24,
      effectiveSnapToGrid: false,
      canEdit: false,
      isPreviewActive: false,
      previewLabel: '',
      isMounted: true,
      otherUserPresences: [],
      currentUserId: undefined,
      viewport: { x: 0, y: 0, zoom: 1 },
      miniMapNodeColor: () => '#000',
      isExecutionFailed: false,
      isExecutionRunning: false,
      workflowExecutionsLink: null,
    },
    sceneController: {
      setCanvasRef: vi.fn(),
      setVueFlowRef: vi.fn(),
    },
    workspaceLink: '/workspaces/ws-1',
    emitSelectCurrent: () => emitAction({ type: 'history.selectCurrent' }),
    emitSelectUndo: (depth: number) =>
      emitAction({ type: 'history.selectUndo', payload: { depth } }),
    emitSelectVersion: (id: string) =>
      emitAction({ type: 'history.selectVersion', payload: { id } }),
    emitApply: () => emitAction({ type: 'history.apply' }),
    emitBack: () => emitAction({ type: 'navigation.backToEditor' }),
  }),
}));

describe('RevisionViewerRoot', () => {
  it('emits grouped revision actions from root controls', async () => {
    const wrapper = mount(RevisionViewerRoot, {
      props: {
        document: {
          workflow: {
            id: 'wf-1',
            name: 'Workflow',
            status: 'draft',
            public: false,
            user_id: 'user-1',
            inserted_at: '2024-01-01T00:00:00Z',
            updated_at: '2024-01-01T00:00:00Z',
            workspace: { name: 'Workspace' },
            workspace_id: 'ws-1',
          },
          draft: {
            id: 'draft-1',
            workflow_id: 'wf-1',
            steps: [],
            connections: [],
            groups: [],
            triggers: [],
            settings: {},
          },
          stepTypes: [],
        },
        history: {
          revision: { kind: 'current', label: 'Current' },
          versions: [],
          undoStack: [],
        },
      },
      global: {
        stubs: {
          WorkflowSceneCanvas: true,
          StepConfigModal: true,
          RevisionHistorySidebar: {
            emits: ['select-current', 'select-undo', 'select-version'],
            template: `
              <div>
                <button id="select-current" @click="$emit('select-current')">Current</button>
                <button id="select-undo" @click="$emit('select-undo', 2)">Undo</button>
                <button id="select-version" @click="$emit('select-version', 'version-1')">Version</button>
              </div>
            `,
          },
        },
      },
    });

    await wrapper.find('#revision-apply-button').trigger('click');
    await wrapper.find('#select-current').trigger('click');
    await wrapper.find('#select-undo').trigger('click');
    await wrapper.find('#select-version').trigger('click');
    await wrapper.find('#revision-back-button').trigger('click');

    expect(wrapper.emitted('action')).toEqual([
      [{ type: 'history.apply' }],
      [{ type: 'history.selectCurrent' }],
      [{ type: 'history.selectUndo', payload: { depth: 2 } }],
      [{ type: 'history.selectVersion', payload: { id: 'version-1' } }],
      [{ type: 'navigation.backToEditor' }],
    ]);
  });
});
