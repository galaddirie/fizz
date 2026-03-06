import { describe, expect, it, vi } from "vitest";

import type { WorkflowEditorDispatch } from "@/features/workflow-editor/contracts/workflowEditor";
import type { StepExecution } from "@/types/workflow";

import { useWorkflowCommands } from "./useWorkflowCommands";

const buildStepExecution = (
  overrides: Partial<StepExecution> = {}
): StepExecution => ({
  id: "exec-1",
  execution_id: "run-1",
  step_id: "step-1",
  step_type_id: "http_request",
  status: "completed",
  output_data: { result: "latest" },
  attempt: 1,
  inserted_at: "2026-03-06T10:00:00Z",
  completed_at: "2026-03-06T10:00:00Z",
  ...overrides,
});

describe("useWorkflowCommands", () => {
  it("dispatches document, step, and group mutations when editing is enabled", () => {
    const dispatch = vi.fn() as WorkflowEditorDispatch;
    const requestNodeRemoval = vi.fn();
    const selectNode = vi.fn();

    const commands = useWorkflowCommands({
      canEdit: () => true,
      dispatch,
      stepExecutions: () => [],
      requestNodeRemoval,
      selectNode,
    });

    commands.document.save();
    commands.execution.runTest();
    commands.execution.cancel();
    commands.selection.selectStep("step-1");
    commands.inspector.saveStepConfig({
      id: "step-1",
      name: "Fetch User",
      config: { method: "GET" },
      notes: "Pull the latest profile",
    });
    commands.inspector.deleteStep("step-1");
    commands.inspector.previewExpression({
      step_id: "step-1",
      field_key: "config.url",
      expression: "{{ trigger.url }}",
    });
    commands.step.run("step-1");
    commands.step.update("step-1", { name: "Updated Name" });
    commands.step.toggleDisabled("step-1", true);
    commands.step.toggleDisabled("step-2", false);
    commands.group.moveSteps({ "step-1": { x: 10, y: 20 } });
    commands.group.moveSteps({
      "step-1": { x: 10, y: 20 },
      "step-2": { x: 30, y: 40 },
    });
    commands.group.update("group-1", { color: "#fff" });

    expect(dispatch).toHaveBeenCalledWith({ type: "document.save" });
    expect(dispatch).toHaveBeenCalledWith({ type: "execution.runTest" });
    expect(dispatch).toHaveBeenCalledWith({ type: "execution.cancel" });
    expect(selectNode).toHaveBeenCalledWith("step-1");
    expect(dispatch).toHaveBeenCalledWith({
      type: "document.step.update",
      payload: {
        step_id: "step-1",
        changes: {
          name: "Fetch User",
          config: { method: "GET" },
          notes: "Pull the latest profile",
        },
      },
    });
    expect(requestNodeRemoval).toHaveBeenCalledWith("step-1");
    expect(dispatch).toHaveBeenCalledWith({
      type: "inspector.previewExpression",
      payload: {
        step_id: "step-1",
        field_key: "config.url",
        expression: "{{ trigger.url }}",
      },
    });
    expect(dispatch).toHaveBeenCalledWith({
      type: "execution.runNode",
      payload: { step_id: "step-1" },
    });
    expect(dispatch).toHaveBeenCalledWith({
      type: "document.step.update",
      payload: {
        step_id: "step-1",
        changes: { name: "Updated Name" },
      },
    });
    expect(dispatch).toHaveBeenCalledWith({
      type: "document.step.enable",
      payload: { step_id: "step-1" },
    });
    expect(dispatch).toHaveBeenCalledWith({
      type: "document.step.disable",
      payload: { step_id: "step-2", mode: "skip" },
    });
    expect(dispatch).toHaveBeenCalledWith({
      type: "document.step.move",
      payload: {
        step_id: "step-1",
        position: { x: 10, y: 20 },
      },
    });
    expect(dispatch).toHaveBeenCalledWith({
      type: "document.step.moveMany",
      payload: {
        step_positions: {
          "step-1": { x: 10, y: 20 },
          "step-2": { x: 30, y: 40 },
        },
      },
    });
    expect(dispatch).toHaveBeenCalledWith({
      type: "document.group.update",
      payload: {
        group_id: "group-1",
        changes: { color: "#fff" },
      },
    });
  });

  it("guards document mutations consistently when editing is disabled", () => {
    const dispatch = vi.fn() as WorkflowEditorDispatch;
    const requestNodeRemoval = vi.fn();
    const selectNode = vi.fn();

    const commands = useWorkflowCommands({
      canEdit: () => false,
      dispatch,
      stepExecutions: () => [],
      requestNodeRemoval,
      selectNode,
    });

    commands.document.save();
    commands.execution.runTest();
    commands.execution.cancel();
    commands.selection.selectStep("step-1");
    commands.inspector.saveStepConfig({
      id: "step-1",
      name: "Fetch User",
      config: {},
    });
    commands.inspector.deleteStep("step-1");
    commands.inspector.previewExpression({
      step_id: "step-1",
      field_key: "config.url",
      expression: "{{ trigger.url }}",
    });
    commands.inspector.pinOutput({
      step_id: "step-1",
      output_data: { result: "latest" },
    });
    commands.inspector.unpinOutput("step-1");
    commands.step.run("step-1");
    commands.step.update("step-1", { name: "Updated Name" });
    commands.step.toggleDisabled("step-1", true);
    commands.step.togglePin("step-1", false);
    commands.group.moveSteps({ "step-1": { x: 10, y: 20 } });
    commands.group.update("group-1", { color: "#fff" });

    expect(requestNodeRemoval).not.toHaveBeenCalled();
    expect(selectNode).toHaveBeenCalledWith("step-1");
    expect(dispatch).toHaveBeenCalledTimes(2);
    expect(dispatch).toHaveBeenCalledWith({ type: "execution.cancel" });
    expect(dispatch).toHaveBeenCalledWith({
      type: "inspector.previewExpression",
      payload: {
        step_id: "step-1",
        field_key: "config.url",
        expression: "{{ trigger.url }}",
      },
    });
  });

  it("pins explicit output and resolves the latest execution for togglePin", () => {
    const dispatch = vi.fn() as WorkflowEditorDispatch;
    const stepExecutions = [
      buildStepExecution({
        id: "exec-1",
        output_data: { result: "older" },
        completed_at: "2026-03-06T10:00:00Z",
      }),
      buildStepExecution({
        id: "exec-2",
        item_index: 2,
        output_data: { result: "latest" },
        completed_at: "2026-03-06T11:00:00Z",
      }),
    ];

    const commands = useWorkflowCommands({
      canEdit: () => true,
      dispatch,
      stepExecutions: () => stepExecutions,
      requestNodeRemoval: vi.fn(),
      selectNode: vi.fn(),
    });

    commands.inspector.pinOutput({
      step_id: "step-1",
      output_data: { result: "explicit" },
      item_index: 3,
    });
    commands.step.togglePin("step-1", false);
    commands.step.togglePin("step-1", true);

    expect(dispatch).toHaveBeenCalledWith({
      type: "document.output.pin",
      payload: {
        step_id: "step-1",
        output_data: { result: "explicit" },
        item_index: 3,
      },
    });
    expect(dispatch).toHaveBeenCalledWith({
      type: "document.output.pin",
      payload: {
        step_id: "step-1",
        output_data: { result: "latest" },
        item_index: 2,
      },
    });
    expect(dispatch).toHaveBeenCalledWith({
      type: "document.output.unpin",
      payload: { step_id: "step-1" },
    });
  });
});
