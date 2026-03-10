# FizzWeb Live Surfaces

The `lib/fizz_web/live` tree owns the authenticated user-facing application shell.

## Route Placement

- Auth-required LiveViews belong in the existing `:browser` + `:require_authenticated_user` scope and `live_session :require_authenticated_user` in [router.ex](../router.ex).
- This route placement matters because [user_auth.ex](../user_auth.ex) assigns `current_scope`, and the LiveViews depend on that assign.
- Workspace-scoped mounts should resolve the workspace with `Accounts.build_scope_for_workspace/2` before reading data.

## Surface Map

- [lib/fizz_web/live/workspaces_live](workspaces_live)
  - Workspace list and workspace detail shell.
- [lib/fizz_web/live/workflow_live](workflow_live)
  - Workflow list, details, editor, and revision views.
- [lib/fizz_web/live/execution_live](execution_live)
  - Execution inspection surfaces.
- [lib/fizz_web/live/sprites_live](sprites_live)
  - Sprite list, console, job, service, and checkpoint UI.
- [lib/fizz_web/live/user_management_live.ex](user_management_live.ex)
  - User settings and membership management.

## Conventions

- Start templates with `<Layouts.app flash={@flash} current_scope={@current_scope}>`.
- Use [Paths](workflow_live/paths.ex) for workflow navigation helpers instead of rebuilding workspace paths inline.
- Use `to_form/2` and `<.input>` for form handling.
- Use LiveView streams for large or frequently refreshed collections.
- The workflow editor and revision viewer use LiveVue components from [assets/vue](../../../assets/vue); LiveView remains the source of truth.

## Read this first

- [lib/fizz_web/router.ex](../router.ex)
- [lib/fizz_web/user_auth.ex](../user_auth.ex)
- [lib/fizz_web/live/workflow_live/paths.ex](workflow_live/paths.ex)
- [lib/fizz_web/live/workflow_live/edit.ex](workflow_live/edit.ex)
