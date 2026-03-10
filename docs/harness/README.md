# Harness Guide

This repo uses harness engineering practices to keep human and agent work legible, reviewable, and mechanically enforced.

## What That Means Here

- `AGENTS.md` is a short routing document, not a policy manual.
- Durable knowledge lives in repo-local markdown close to the code that owns it.
- Multi-step work is tracked in [docs/plans](../plans/README.md).
- Structural changes update docs in the same diff as the code.

## Working Loop

1. Read [ARCHITECTURE.md](../../ARCHITECTURE.md) and the nearest subsystem README before editing.
2. If the work crosses subsystems, spans multiple sessions, or has open questions, create a plan from [docs/plans/TEMPLATE.md](../plans/TEMPLATE.md).
3. Keep edits inside the owning context instead of scattering behavior across layers.
4. Update the relevant README when ownership, entry points, or common flows change.
5. Run `mix precommit`.

## Repo Conventions Worth Remembering

- Use `Req` for HTTP.
- Auth-required LiveViews belong in the existing `:browser` + `:require_authenticated_user` scope and `live_session :require_authenticated_user` because that is where `current_scope` is assigned.
- Pass `current_scope` as the first argument to auth-sensitive context functions.
- LiveView templates should begin with `<Layouts.app flash={@flash} current_scope={@current_scope}>`.
- Prefer `<.input>`, `<.icon>`, `to_form/2`, and LiveView streams over hand-rolled alternatives.
- Keep Vue code under `assets/vue`; LiveView stays the source of truth for server state. 
- When adding a new durable subsystem, create a local `README.md` next to it and link it from [ARCHITECTURE.md](../../ARCHITECTURE.md).

## Verification

- Use `mix precommit` as the final verification step.
- If a harness-oriented change updates repo structure or docs, review the linked markdown files in the same diff instead of relying on a separate custom check.
