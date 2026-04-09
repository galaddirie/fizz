2. [High] Sensitive data exposure from evaluated config + verbose payload logging.
    lib/fizz/runtime/steps/step_runner.ex:145 stores full "evaluated_config" into step execution
    metadata. That metadata is encoded to the client in lib/fizz/executions/step_execution.ex:9.
    Also, full operation payloads are logged at info/error in lib/fizz/collaboration/edit_session/
    operations.ex:84 and lib/fizz/collaboration/edit_session/operations.ex:96.


3. [High] Execution runs under workflow owner scope, not triggering user scope.
    lib/fizz/runtime/execution/server.ex:271 builds runtime scope from execution.workflow.user and
    project, while execution records track triggered_by_user_id from request time (lib/fizz/
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


I also want to capture the non technical audience to differentiate myself from other engines like n8n. I want to convey the power of my engine at the same time. our workflows are stateful, can be long lived, durable, reactive, living models ex. Imagine a workflow that can react and change its behaviors based on the state of previous executions, not just run once forget and fire workflows. ex. a workflow agent that updates a/b tests but changes based on the results of the previous workflow, or a workflow that is multi-week event planning that maintains the evolving plan (venue, budget, guest list, vendors), nudges owners before deadlines, reacts to changes/cancellations, and keeps a single “source of truth” until the event is done.


workflow example like Coordinates interviews, keeps candidates warm, maintains scorecards, reduces drop-off over single execution that spans weeks


Imagine you trigger a workflow to optimize and monitor a site and or to run experiements and update code for a period of 6 months - this would be  a single execution. 



Why does this product exisit 

Agentic work is a unsolved problem.  and its largerly because getting the abstraction right is hard, getting right for both non technical and technical users is even harder.

there are so many solutions out there trying to solve the same core problem but tacking only a subset

You have n8n, openclaw, codex, claude code. 

which one is correct - run once ridgid workflows like n8n, or forever running full anotonomous personal assistants like open claw, or stateful adhoc agents like codex, or claude code that does scoped work to completion.

all of the soultions are technically correct in their own way, i personally belive the solution is some where in the middle of all of them.

its primarily a design issue. 


what we are trying to build is the bounded/scoped agentic work like codex, modeled and triggered by events and signals in a workflow ux like n8n, in stateful long running proccess like open claw.


for the demo we will show a workflow that constantly adds + 1 to a number stored in a state machine. and every time it finds a prime number it will send a message overe whatsapp 

simple email agent with human in the loop for deletion of emails 

add a chat endpoint that can use natural language to determine which workflow to run based on the user's input. it will use workflow names, descriptions, and projects to determine the best workflow to run. could run multiple workflows - this is a ux feature



workflow example idea

A bot that starts an a/b experiment and updates the experiments based on events and signals from Google Analytics or the website itself updating the experiment continuously.

 bot that can detect errors, triage them, and update the website, then emails the user the issue and the fix.



 - [ ] Users should be able to pin data without needing to run a node. they should be able to paste a payload of their shape 
 - [ ] add loop zone like ui from blender to spliter aggregate pairs. add ux that lets user paginate through the iterations 


 bugs 


- When we open a a debug workflow mode by visting workflow/<workflow_id>/edit/runs/<run_id>, it does not rebuild the graph from the logs, it shows the current a view with the currentdraft model ( have not tested with published workflows )


what should the debug view show? what should the user experience be? how will users debug and pin workflows on published versions or previous drafts if they drift significantly from the current draft?

c/workflows/\/edit/runs/648c061d-0b09-4cbe-9765-09fd578de200


BUG
Pinned outputs dont actually work. they appear to work in the ui on the pinned node (showing the input and the correct pinned output) but when you look at the downstream nodes, they are using real live output, not the pinned output.

we honestly shouldnt even be executing nodes with pinned outputs so how is this happening.

- Research workflow execution check points during live runs
- Research post-terminal SQLite /litestream/minio compaction: checkpoint completed/cancelled/failed workflows

