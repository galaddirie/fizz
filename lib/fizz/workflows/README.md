# Fizz Workflow Engine

The workflow engine owns workflow authoring, validation, persistence, execution tracking, runtime evaluation, and collaborative editing.

## Owns

- workflow records, drafts, and published versions
- workflow validation and contract generation
- step type registry and executor conventions
- execution and step execution persistence
- runtime execution, trigger activation, and expression resolution
- collaborative draft editing and undo/redo
- workflow and execution LiveViews, including the LiveVue editor surfaces

## Does Not Own

- workspace and organization authorization
  - See [lib/fizz/accounts/README.md](../accounts/README.md)
- provider credential persistence
  - See [lib/fizz/accounts/README.md](../accounts/README.md)
- remote sprite lifecycle and console/job brokering
  - See [lib/fizz/sprites/README.md](../sprites/README.md)

## Module Map

- [lib/fizz/workflows.ex](../workflows.ex)
  - Workflow CRUD, draft/version access, webhook lookup, and authorization-aware queries.
- [lib/fizz/workflows](.)
  - Schemas, embeds, validation, and contract generation.
- [lib/fizz/steps](../steps.ex)
  - Step registry, type metadata, config schema helpers, and executor definitions.
- [lib/fizz/executions.ex](../executions.ex)
  - Execution lifecycle, step execution persistence, and authorization-aware inspection.
- [lib/fizz/runtime](../runtime)
  - Runtime supervisor, execution server, expression evaluation, triggers, and step runner.
- [lib/fizz/collaboration](../collaboration)
  - Collaborative editor state, operation application, undo/redo, and draft persistence.
- [lib/fizz_web/live/workflow_live](../../fizz_web/live/workflow_live)
  - Workflow index/show/edit/revision UI entry points.
- [lib/fizz_web/live/execution_live](../../fizz_web/live/execution_live)
  - Execution inspection UI.
- [assets/vue/WorkflowEditor.vue](../../../assets/vue/WorkflowEditor.vue)
  - Primary graph editor surface used by `WorkflowLive.Edit`.

## Common Flows

### Author a workflow

1. [WorkflowLive.Edit](../../fizz_web/live/workflow_live/edit.ex) loads the workflow and current draft.
2. [Fizz.Collaboration.EditSession.Server](../collaboration/edit_session/server.ex) becomes the source of truth for draft edits.
3. [WorkflowEditor.vue](../../../assets/vue/WorkflowEditor.vue) renders the graph through LiveVue while LiveView owns persistence and events.

### Validate or publish a workflow

1. [Fizz.Workflows.Validator](validator.ex) checks graph structure and config.
2. [Fizz.Workflows.Contract](contract.ex) derives the execution contract used by external callers.
3. [Fizz.Workflows](../workflows.ex) persists draft or published state.

### Run and inspect an execution

1. [Fizz.Executions](../executions.ex) creates the execution record.
2. [Fizz.Runtime.Execution.Server](../runtime/execution/server.ex) runs the workflow and writes step execution data.
3. [ExecutionLive.Show](../../fizz_web/live/execution_live/show.ex) streams the results back to the user.

## Read this first

- [lib/fizz/workflows.ex](../workflows.ex)
- [lib/fizz_web/live/workflow_live/edit.ex](../../fizz_web/live/workflow_live/edit.ex)
- [lib/fizz/runtime/execution/server.ex](../runtime/execution/server.ex)
- [lib/fizz/collaboration/edit_session/server.ex](../collaboration/edit_session/server.ex)
