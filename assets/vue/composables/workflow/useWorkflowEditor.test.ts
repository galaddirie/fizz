import { describe, expect, it } from "vitest";
import type { GraphNode } from "@vue-flow/core";

import type { WorkflowNodeData } from "@/shared/ui/workflow-scene/types";
import type {
  NodeLibraryItem,
  StepHandleQuickAddRequest,
} from "@/types/workflow";

import {
  buildAddStepPickerItems,
  resolveAddStepSize,
} from "./useWorkflowEditor";

const nodeLibraryItems: NodeLibraryItem[] = [
  {
    type_id: "http_request",
    name: "HTTP Request",
    description: "Call an API",
    category: "Core",
    icon: "hero-globe",
    step_kind: "action",
  },
  {
    type_id: "trigger",
    name: "Trigger",
    description: "Start the workflow",
    category: "Core",
    icon: "hero-bolt",
    step_kind: "trigger",
  },
  {
    type_id: "subnode-a",
    name: "Subnode A",
    description: "Subnode",
    category: "Core",
    icon: "hero-square-3-stack-3d",
    step_kind: "action",
    node_role: "subnode",
  },
  {
    type_id: "subnode-b",
    name: "Subnode B",
    description: "Subnode",
    category: "Core",
    icon: "hero-square-3-stack-3d",
    step_kind: "action",
    node_role: "subnode",
  },
];

const buildQuickAddRequest = (
  overrides: Partial<StepHandleQuickAddRequest> = {}
): StepHandleQuickAddRequest => ({
  screenPoint: { x: 10, y: 20 },
  filter: { mode: "subnode_slot" },
  autoConnect: { source_step_id: "step-1", source_output: "default" },
  ...overrides,
});

const createGraphNode = (
  id: string,
  type: string,
  width: number,
  height: number
): GraphNode<WorkflowNodeData> =>
  ({
    id,
    type,
    position: { x: 0, y: 0 },
    computedPosition: { x: 0, y: 0, z: 0 },
    dimensions: { width, height },
    data:
      type === "group"
        ? {
            id,
            name: "Group",
            step_ids: [],
            collapsed: false,
          }
        : {
            id,
            type_id: "http_request",
            name: "Step",
            config: {},
            hasInput: true,
            hasOutput: true,
          },
  } as GraphNode<WorkflowNodeData>);

describe("useWorkflowEditor helpers", () => {
  it("filters add-step picker items for quick-add mode", () => {
    expect(buildAddStepPickerItems(nodeLibraryItems, null)).toHaveLength(4);

    expect(
      buildAddStepPickerItems(
        nodeLibraryItems,
        buildQuickAddRequest({ filter: { mode: "output" } })
      ).map((item) => item.type_id)
    ).toEqual(["http_request"]);

    expect(
      buildAddStepPickerItems(
        nodeLibraryItems,
        buildQuickAddRequest({
          filter: {
            mode: "subnode_slot",
            accepted_type_ids: ["subnode-b"],
          },
        })
      ).map((item) => item.type_id)
    ).toEqual(["subnode-b"]);
  });

  it("resolves measured node sizes before falling back to defaults", () => {
    const nodes = [
      createGraphNode("step-template", "step", 420, 180),
      createGraphNode("subnode-template", "subnode", 160, 90),
    ];

    expect(resolveAddStepSize(nodeLibraryItems, nodes, "http_request")).toEqual(
      {
        width: 420,
        height: 180,
      }
    );
    expect(resolveAddStepSize(nodeLibraryItems, nodes, "subnode-a")).toEqual({
      width: 160,
      height: 90,
    });
  });
});
