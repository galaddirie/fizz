import { describe, expect, it, vi } from "vitest";
import type { Node } from "@vue-flow/core";

import type { StepNodeData } from "@/shared/ui/workflow-scene/types";
import type { useClientStore } from "@/stores/clientStore";

import { useContextMenu } from "./useContextMenu";

const createStepNode = (data: Partial<StepNodeData> = {}): Node<StepNodeData> =>
  ({
    id: "step-1",
    type: "step",
    position: { x: 0, y: 0 },
    data: {
      id: "step-1",
      type_id: "http_request",
      name: "Fetch User",
      config: {},
      hasInput: true,
      hasOutput: true,
      ...data,
    },
  } as Node<StepNodeData>);

const createStore = (overrides: Record<string, unknown> = {}) =>
  ({
    contextMenu: {
      targetType: "node",
      targetNodeId: "step-1",
      x: 120,
      y: 240,
    },
    openConfigModal: vi.fn(),
    hideContextMenu: vi.fn(),
    ...overrides,
  } as unknown as ReturnType<typeof useClientStore>);

const createOptions = (
  overrides: Partial<Parameters<typeof useContextMenu>[0]> = {}
) => {
  const store = createStore();

  return {
    store,
    canEdit: () => true,
    state: {
      tidyLabel: () => "Tidy Up Workflow",
      canPaste: () => true,
      canGroupSelection: () => false,
      canUngroupSelection: () => false,
    },
    lookup: {
      findStepNodeById: () => createStepNode(),
      resolveActiveNodeIds: () => ["step-1"],
    },
    commands: {
      canvas: {
        openAddStepPicker: vi.fn(),
        fitView: vi.fn(),
        selectAll: vi.fn(),
      },
      group: {
        createFromSelection: vi.fn(),
        ungroupSelection: vi.fn(),
        remove: vi.fn(),
        tidy: vi.fn(),
      },
      clipboard: {
        duplicate: vi.fn(),
        copy: vi.fn(),
        cut: vi.fn(),
        paste: vi.fn(),
      },
      step: {
        inspect: vi.fn(),
        remove: vi.fn(),
        run: vi.fn(),
        toggleDisabled: vi.fn(),
        togglePin: vi.fn(),
      },
    },
    ...overrides,
  };
};

describe("useContextMenu", () => {
  it("builds readonly step actions and executes inspect", () => {
    const options = createOptions({
      canEdit: () => false,
    });

    const contextMenu = useContextMenu(options);

    expect(contextMenu.contextMenuItems.value.map((item) => item.id)).toEqual([
      "inspect",
      "divider-1",
      "fit-view",
    ]);

    contextMenu.handleContextMenuSelect("inspect");

    expect(options.commands.step.inspect).toHaveBeenCalledWith("step-1");
    expect(options.store.hideContextMenu).toHaveBeenCalledTimes(1);
  });

  it("builds editable step actions and routes commands through the registry", () => {
    const options = createOptions({
      state: {
        tidyLabel: () => "Tidy Up Selection",
        canPaste: () => true,
        canGroupSelection: () => true,
        canUngroupSelection: () => true,
      },
      lookup: {
        findStepNodeById: () =>
          createStepNode({
            disabled: true,
            pinned: false,
          }),
        resolveActiveNodeIds: () => ["step-1", "step-2"],
      },
    });

    const contextMenu = useContextMenu(options);

    expect(contextMenu.contextMenuItems.value.map((item) => item.id)).toContain(
      "group-selection"
    );
    expect(contextMenu.contextMenuItems.value.map((item) => item.id)).toContain(
      "toggle-disable"
    );

    contextMenu.handleContextMenuSelect("duplicate");
    contextMenu.handleContextMenuSelect("toggle-disable");
    contextMenu.handleContextMenuSelect("toggle-pin");
    contextMenu.handleContextMenuSelect("delete");

    expect(options.commands.clipboard.duplicate).toHaveBeenCalledWith([
      "step-1",
      "step-2",
    ]);
    expect(options.commands.step.toggleDisabled).toHaveBeenCalledWith(
      "step-1",
      true
    );
    expect(options.commands.step.togglePin).toHaveBeenCalledWith(
      "step-1",
      false
    );
    expect(options.commands.step.remove).toHaveBeenCalledWith("step-1");
  });

  it("executes pane commands for add, select all, and fit view", () => {
    const options = createOptions({
      store: createStore({
        contextMenu: {
          targetType: "pane",
          targetNodeId: null,
          x: 64,
          y: 96,
        },
      }),
      state: {
        tidyLabel: () => "Tidy Up Workflow",
        canPaste: () => false,
        canGroupSelection: () => false,
        canUngroupSelection: () => false,
      },
    });

    const contextMenu = useContextMenu(options);
    const pasteItem = contextMenu.contextMenuItems.value.find(
      (item) => item.id === "paste"
    );

    expect(pasteItem?.disabled).toBe(true);

    contextMenu.handleContextMenuSelect("add-step");
    contextMenu.handleContextMenuSelect("select-all");
    contextMenu.handleContextMenuSelect("fit-view");

    expect(options.commands.canvas.openAddStepPicker).toHaveBeenCalledWith({
      x: 64,
      y: 96,
    });
    expect(options.commands.canvas.selectAll).toHaveBeenCalledTimes(1);
    expect(options.commands.canvas.fitView).toHaveBeenCalledTimes(1);
  });
});
