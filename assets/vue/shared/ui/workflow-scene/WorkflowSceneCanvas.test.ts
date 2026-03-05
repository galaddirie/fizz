import { defineComponent } from 'vue';
import { mount } from '@vue/test-utils';
import { describe, expect, it, vi } from 'vitest';

import WorkflowSceneCanvas from './WorkflowSceneCanvas.vue';
import type { WorkflowSceneController, WorkflowSceneModel } from './types';

const ControlsStub = defineComponent({
  props: {
    showInteractive: {
      type: Boolean,
      default: false,
    },
  },
  template: `
    <div class="controls-stub">
      <slot name="top" />
      <slot />
    </div>
  `,
});

const ExecutionOverlayStub = defineComponent({
  emits: ['run', 'cancel'],
  template: `
    <div class="execution-overlay-stub">
      <button id="run-action" @click="$emit('run')">Run</button>
      <button id="cancel-action" @click="$emit('cancel')">Cancel</button>
    </div>
  `,
});

const buildSceneModel = (canEdit: boolean): WorkflowSceneModel => ({
  nodes: [],
  edges: [],
  nodeTypes: {},
  edgeTypes: {},
  snapEnabled: canEdit,
  gridSize: 24,
  effectiveSnapToGrid: canEdit,
  canEdit,
  isPreviewActive: true,
  previewLabel: 'Preview mode',
  isMounted: true,
  otherUserPresences: [],
  currentUserId: 'user-1',
  viewport: { x: 0, y: 0, zoom: 1 },
  miniMapNodeColor: () => '#000',
  isExecutionFailed: false,
  isExecutionRunning: true,
  workflowExecutionsLink: '/workflows/wf-1',
});

const buildSceneController = (): WorkflowSceneController => ({
  setCanvasRef: vi.fn(),
  setVueFlowRef: vi.fn(),
  onToggleSnap: vi.fn(),
  onRunTest: vi.fn(),
  onCancelExecution: vi.fn(),
});

describe('WorkflowSceneCanvas', () => {
  it('renders editable controls and forwards actions', async () => {
    const controller = buildSceneController();

    const wrapper = mount(WorkflowSceneCanvas, {
      props: {
        model: buildSceneModel(true),
        controller,
      },
      global: {
        stubs: {
          VueFlow: { template: '<div class="vue-flow-stub"><slot /></div>' },
          Background: true,
          Controls: ControlsStub,
          MiniMap: true,
          CollaborativeCursors: true,
          ExecutionOverlay: ExecutionOverlayStub,
        },
      },
    });

    expect(wrapper.text()).toContain('Preview mode');
    expect(wrapper.find('[aria-label="Toggle snap to grid"]').exists()).toBe(true);

    await wrapper.find('[aria-label="Toggle snap to grid"]').trigger('click');
    await wrapper.find('#run-action').trigger('click');
    await wrapper.find('#cancel-action').trigger('click');

    expect(controller.onToggleSnap).toHaveBeenCalledTimes(1);
    expect(controller.onRunTest).toHaveBeenCalledTimes(1);
    expect(controller.onCancelExecution).toHaveBeenCalledTimes(1);
  });

  it('hides editable controls in readonly mode', () => {
    const wrapper = mount(WorkflowSceneCanvas, {
      props: {
        model: buildSceneModel(false),
        controller: buildSceneController(),
      },
      global: {
        stubs: {
          VueFlow: { template: '<div class="vue-flow-stub"><slot /></div>' },
          Background: true,
          Controls: ControlsStub,
          MiniMap: true,
          CollaborativeCursors: true,
          ExecutionOverlay: ExecutionOverlayStub,
        },
      },
    });

    expect(wrapper.find('[aria-label="Toggle snap to grid"]').exists()).toBe(false);
  });
});

