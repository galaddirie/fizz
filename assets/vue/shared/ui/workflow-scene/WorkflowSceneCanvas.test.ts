import { defineComponent } from "vue";
import { mount } from "@vue/test-utils";
import { describe, expect, it, vi } from "vitest";

import WorkflowSceneCanvas from "./WorkflowSceneCanvas.vue";
import type { WorkflowSceneController, WorkflowSceneModel } from "./types";

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

const buildSceneModel = (canEdit: boolean): WorkflowSceneModel => ({
  nodes: [],
  edges: [],
  nodeTypes: {},
  edgeTypes: {},
  snapEnabled: canEdit,
  gridSize: 24,
  effectiveSnapToGrid: canEdit,
  canEdit,
  miniMapNodeColor: () => "#000",
});

const buildSceneController = (): WorkflowSceneController => ({
  setCanvasRef: vi.fn(),
  setVueFlowRef: vi.fn(),
  onToggleSnap: vi.fn(),
});

describe("WorkflowSceneCanvas", () => {
  it("renders editable controls and forwards actions", async () => {
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
        },
      },
      slots: {
        overlay: '<div class="overlay-slot">Overlay</div>',
      },
    });

    expect(wrapper.text()).toContain("Overlay");
    expect(wrapper.find('[aria-label="Toggle snap to grid"]').exists()).toBe(
      true
    );

    await wrapper.find('[aria-label="Toggle snap to grid"]').trigger("click");

    expect(controller.onToggleSnap).toHaveBeenCalledTimes(1);
  });

  it("hides editable controls in readonly mode", () => {
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
        },
      },
    });

    expect(wrapper.find('[aria-label="Toggle snap to grid"]').exists()).toBe(
      false
    );
  });
});
