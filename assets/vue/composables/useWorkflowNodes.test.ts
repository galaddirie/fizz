import { describe, expect, it } from "vitest";

import type {
  EditorState,
  StepExecution,
  Step,
  StepType,
  UserPresence,
  Workflow,
} from "@/types/workflow";
import type { StepNodeData } from "@/shared/ui/workflow-scene/types";

import { useWorkflowNodes } from "./useWorkflowNodes";

const buildWorkflow = (): Workflow => ({
  id: "workflow-1",
  name: "Workflow",
  status: "draft",
  public: false,
  user_id: "user-1",
  inserted_at: "2026-03-06T10:00:00Z",
  updated_at: "2026-03-06T10:00:00Z",
  draft: {
    id: "draft-1",
    workflow_id: "workflow-1",
    steps: [
      {
        id: "step-1",
        type_id: "http_request",
        name: "Fetch User",
        config: { method: "GET" },
        position: { x: 10, y: 20 },
        notes: "Fetch the latest user",
      },
      {
        id: "step-2",
        type_id: "trigger",
        name: "Trigger",
        config: {},
        position: { x: 200, y: 120 },
      },
    ],
    connections: [],
    groups: [
      {
        id: "group-1",
        name: "Main Group",
        step_ids: ["step-1"],
        output_step_id: "step-1",
        position: { x: 5, y: 15, width: 320, height: 180 },
        color: "#123456",
        font_size: 18,
        collapsed: false,
      },
    ],
    triggers: [],
    settings: {},
  },
});

const buildStepType = (overrides: Partial<StepType> = {}): StepType => ({
  id: "http_request",
  name: "HTTP Request",
  category: "Core",
  icon: "hero-globe",
  step_kind: "action",
  ...overrides,
});

const buildExecution = (
  overrides: Partial<StepExecution> = {}
): StepExecution => ({
  id: "exec-1",
  execution_id: "run-1",
  step_id: "step-1",
  step_type_id: "http_request",
  status: "completed",
  output_data: { ok: true },
  output_item_count: 1,
  attempt: 1,
  duration_us: 1_000,
  inserted_at: "2026-03-06T10:00:00Z",
  completed_at: "2026-03-06T10:00:01Z",
  ...overrides,
});

describe("useWorkflowNodes", () => {
  it("projects group and step nodes with collaboration overlays", () => {
    const workflow = buildWorkflow();
    const editorState: EditorState = {
      workflow_id: workflow.id,
      pinned_outputs: { "step-1": { ok: true } },
      disabled_steps: ["step-1"],
      step_locks: { "step-1": "user-2" },
    };
    const presences: UserPresence[] = [
      {
        user: { id: "user-1", name: "Current User" },
        dragging_steps: { "step-1": { x: 1, y: 2 } },
      },
      {
        user: { id: "user-2", name: "Avery" },
        selected_steps: ["step-1"],
        dragging_steps: { "step-1": { x: 150, y: 175 } },
        dragging_groups: {
          "group-1": { x: 25, y: 35, width: 420, height: 260 },
        },
      },
    ];

    const { nodes } = useWorkflowNodes({
      workflow: () => workflow,
      stepTypes: () => [
        buildStepType(),
        buildStepType({ id: "trigger", step_kind: "trigger" }),
      ],
      stepExecutions: () => [buildExecution()],
      editorState: () => editorState,
      presences: () => presences,
      currentUserId: () => "user-1",
      canEdit: () => false,
      collabSeq: () => 7,
      groupingPreview: () => ({
        groupId: "group-1",
        stepIds: ["step-1"],
        color: "#fedcba",
      }),
    });

    const groupNode = nodes.value.find((node) => node.id === "group-1");
    const stepNode = nodes.value.find((node) => node.id === "step-1") as
      | (typeof nodes.value)[number]
      | undefined;
    const stepNodeData = stepNode?.data as StepNodeData | undefined;

    expect(groupNode?.position).toEqual({ x: 25, y: 35 });
    expect(groupNode?.style).toEqual({ width: "420px", height: "260px" });
    expect(groupNode?.data).toMatchObject({
      isGroupingTarget: true,
      groupingColor: "#fedcba",
      collabSeq: 7,
      canEdit: false,
    });

    expect(stepNode?.position).toEqual({ x: 150, y: 175 });
    expect(stepNode?.parentNode).toBe("group-1");
    expect(stepNodeData).toMatchObject({
      disabled: true,
      pinned: true,
      locked_by: "user-2",
      isGroupingCandidate: true,
      groupingColor: "#fedcba",
      canEdit: false,
    });
    expect(stepNodeData?.selected_by).toEqual([
      {
        id: "user-2",
        name: "Avery",
        color: expect.any(String),
      },
    ]);
  });

  it("aggregates multi-item execution status and duration for step nodes", () => {
    const workflow = buildWorkflow();
    workflow.draft!.groups = [];
    workflow.draft!.steps = [workflow.draft!.steps[0] as Step];

    const { nodes } = useWorkflowNodes({
      workflow: () => workflow,
      stepTypes: () => [buildStepType()],
      stepExecutions: () => [
        buildExecution({
          id: "exec-1",
          item_index: 0,
          items_total: 2,
          status: "completed",
          started_at: "2026-03-06T10:00:00Z",
          completed_at: "2026-03-06T10:00:10Z",
          output_item_count: 1,
        }),
        buildExecution({
          id: "exec-2",
          item_index: 1,
          items_total: 2,
          status: "failed",
          started_at: "2026-03-06T10:00:05Z",
          completed_at: "2026-03-06T10:00:25Z",
          output_item_count: 2,
        }),
      ],
      editorState: () => undefined,
      presences: () => [],
      currentUserId: () => "user-1",
    });

    const stepNode = nodes.value[0];
    const stepNodeData = stepNode.data as StepNodeData;

    expect(stepNodeData.itemStats).toEqual({
      isMultiItem: true,
      itemsTotal: 2,
      completed: 1,
      failed: 1,
      running: 0,
    });
    expect(stepNodeData.status).toBe("failed");
    expect(stepNodeData.stats).toEqual({
      duration_us: 25_000_000,
      out: 1,
    });
  });
});
