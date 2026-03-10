# Fizz Architecture

Fizz is organized around three durable domains: identity and tenancy, the workflow engine, and the Sprites execution broker. Phoenix LiveView is the main UI shell, and LiveVue is used for the graph-heavy workflow editor surfaces.

## System Map

- [lib/fizz/accounts/README.md](lib/fizz/accounts/README.md)
  - Identity, tenancy, WorkOS integration, workspace membership, and provider auth persistence.
- [lib/fizz/workflows/README.md](lib/fizz/workflows/README.md)
  - Workflow definitions, drafts and versions, step registry, execution persistence, runtime, triggers, and collaborative editing.
- [lib/fizz/sprites/README.md](lib/fizz/sprites/README.md)
  - Remote sprite lifecycle, exec jobs, consoles, services, checkpoints, and broker workers.
  - Background on the external platform lives in [lib/fizz/sprites/platform-overview.md](lib/fizz/sprites/platform-overview.md).
- [lib/fizz_web/live/README.md](lib/fizz_web/live/README.md)
  - Authenticated UI surfaces, route placement, workspace-scoped mounts, and LiveVue entry points.

## Main Request Flows

### Authenticated UI flow

1. [router.ex](lib/fizz_web/router.ex) places user-facing routes inside the existing `:browser` and `:require_authenticated_user` pipelines.
2. [user_auth.ex](lib/fizz_web/user_auth.ex) resolves `current_scope`.
3. LiveViews call `Accounts.build_scope_for_workspace/2` before workspace-scoped reads and writes.

### Workflow authoring and execution

1. [WorkflowLive.Edit](lib/fizz_web/live/workflow_live/edit.ex) mounts the editor and hands graph state to [WorkflowEditor.vue](assets/vue/WorkflowEditor.vue) through LiveVue.
2. [Fizz.Collaboration.EditSession.Server](lib/fizz/collaboration/edit_session/server.ex) owns collaborative draft state, undo/redo, and persistence.
3. [Fizz.Workflows](lib/fizz/workflows.ex) persists workflows, drafts, versions, and publication metadata.
4. [Fizz.Executions](lib/fizz/executions.ex) creates and tracks executions and step executions.
5. [Fizz.Runtime.Execution.Server](lib/fizz/runtime/execution/server.ex) runs published or preview workflows with [Fizz.Runtime.Steps.StepRunner](lib/fizz/runtime/steps/step_runner.ex).
6. [ExecutionLive.Show](lib/fizz_web/live/execution_live/show.ex) streams execution state back to the user.

### Sprite broker flow

1. [WorkspacesLive.Show](lib/fizz_web/live/workspaces_live/show.ex) links into the workspace broker surfaces.
2. [SpritesLive.Show](lib/fizz_web/live/sprites_live/show.ex) opens consoles, queues jobs, and manages checkpoints and services.
3. [Fizz.Sprites](lib/fizz/sprites.ex) coordinates local persistence, remote client calls, and Oban workers under [lib/fizz/sprites/workers](lib/fizz/sprites/workers).
4. [Fizz.Integrations](lib/fizz/integrations.ex) resolves provider auth material when sprite actions need external APIs.

## Read Order

1. [README.md](README.md)
2. [AGENTS.md](AGENTS.md)
3. One of the subsystem READMEs linked above
4. The owning context module and the matching LiveView

## Change Rule

When a change alters ownership, entry points, or a multi-step workflow, update the nearest subsystem README and the relevant plan in [docs/plans](docs/plans/README.md) in the same diff.
