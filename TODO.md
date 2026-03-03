2. [High] Sensitive data exposure from evaluated config + verbose payload logging.
    lib/fizz/runtime/steps/step_runner.ex:145 stores full "evaluated_config" into step execution
    metadata. That metadata is encoded to the client in lib/fizz/executions/step_execution.ex:9.
    Also, full operation payloads are logged at info/error in lib/fizz/collaboration/edit_session/
    operations.ex:84 and lib/fizz/collaboration/edit_session/operations.ex:96.


3. [High] Execution runs under workflow owner scope, not triggering user scope.
    lib/fizz/runtime/execution/server.ex:271 builds runtime scope from execution.workflow.user and
    workspace, while execution records track triggered_by_user_id from request time (lib/fizz/
    executions.ex:221).
    This can produce permission drift for preview/partial runs.
    Better pattern: resolve runtime scope from triggered_by_user_id when present, fallback to system
    scope only for internal triggers.
4. [High] Race between status persistence and event emission can produce stale UI state.
    lib/fizz/runtime/execution/server.ex:324 and lib/fizz/runtime/execution/server.ex:335 update DB
    status in detached Task.start/1, but events are emitted immediately at lib/fizz/runtime/execution/
    server.ex:158 and lib/fizz/runtime/execution/server.ex:182.
    The LiveView then re-fetches from DB on event at lib/fizz_web/live/workflow_live/edit.ex:1008,
    which can read pre-update status.
    Better pattern: persist status synchronously, then emit event, so event ordering matches committed
    state.


6. [Medium] Multi-op UX actions are not atomic and can partially apply.
    lib/fizz_web/live/workflow_live/edit.ex:1116 applies operations sequentially and halts on first
    error. duplicate_steps and tidy_layout depend on this (lib/fizz_web/live/workflow_live/edit.ex:358,
    lib/fizz_web/live/workflow_live/edit.ex:406), so partial state is possible.
    Better pattern: server-side apply_operations/3 that prevalidates all operations, then applies as
    one logical unit.

7. [Medium] Session memory/DB work grows more than necessary over long editing sessions.
    applied_ops grows unbounded (lib/fizz/collaboration/edit_session/server.ex:451).
    Persistence inserts full op_buffer on each dirty flush (lib/fizz/collaboration/edit_session/
    persistence.ex:41), while buffer is capped but reused (lib/fizz/collaboration/edit_session/
    server.ex:1146).
    Better pattern: keep a bounded recent-id cache for dedupe and a separate unpersisted queue for
    persistence.

8. [Medium] Payload shape normalization is spread everywhere instead of handled once.
    Repeated atom/string dual-access helpers exist in multiple modules (lib/fizz_web/live/
    workflow_live/edit.ex:1282, lib/fizz/collaboration/edit_session/operations.ex:22, lib/fizz/
    collaboration/edit_session/inversion.ex:225, lib/fizz/executions.ex:229).
    Undo payload shape is camelCase from server (lib/fizz/collaboration/edit_session/server.ex:556)
    while most operation payload keys are snake_case.
    Better pattern: normalize at boundary once into typed internal structs/maps.




Maintainability Summary

- Main pressure points are module size and responsibility mixing:
lib/fizz_web/live/workflow_live/edit.ex (2135 LoC), lib/fizz/collaboration/edit_session/server.ex
(1215), lib/fizz/collaboration/edit_session/operations.ex (914), lib/fizz/runtime/runic_adapter.ex
(1100).
- Clean building blocks for lower LoC per unit would be:



1. WorkflowEditorLive as transport layer only (mount/render/dispatch).
2. EditorSession command API (apply_command, apply_batch, undo/redo).
3. Is Runtime.Events planned as a migration layer, or should it replace Executions.PubSub entirely?


when adding subnodes through the quick add buttons, the position is not correct.

when laying out nodes, nodes should be aware of near by group nodes to avoid overlapping.

update debug and revision view to match the new seamless shell UI.



WORKFLOW IDEAS

Imagine stateful agent that runs every day checks the  performance of a website. the agent can run a/b tests and store the results in a statemachine. 

meanign the agent can refine and update the website content based on the results of the a/b tests. 

we can even have triggers aswell incombination with the schedule trigger - ex. a sales/converstion trigger where the a/b test is successful the agent can then react and update a/b test again 

An event-driven workflow engine where agents execute durable, observable work—across apps, infra, and teams