# Fizz Agent Guide

Fizz is a Phoenix 1.8 + LiveView + LiveVue application for workspace-scoped workflows, executions, and Sprites.

## First Read

- [README.md](README.md)
- [ARCHITECTURE.md](ARCHITECTURE.md)
- [docs/harness/README.md](docs/harness/README.md)
- [docs/plans/README.md](docs/plans/README.md)

## Subsystem Maps

- [lib/fizz/accounts/README.md](lib/fizz/accounts/README.md)
- [lib/fizz/workflows/README.md](lib/fizz/workflows/README.md)
- [lib/fizz/sprites/README.md](lib/fizz/sprites/README.md)
- [lib/fizz/steps/executors/README.md](lib/fizz/steps/executors/README.md)
- [lib/fizz_web/live/README.md](lib/fizz_web/live/README.md)

## Working Rules

- Use `mix setup` for first-time setup and `mix phx.server` for local development.
- Run `mix precommit` before handoff.
- Use `Req` for HTTP; do not add `HTTPoison`, `Tesla`, or `:httpc`.
- Keep auth-required LiveViews inside the existing `:browser` + `:require_authenticated_user` scope and `live_session :require_authenticated_user`.
- Pass `current_scope` as the first argument to context functions that depend on tenancy or auth.
- Start LiveView templates with `<Layouts.app flash={@flash} current_scope={@current_scope}>`.
- Use `<.input>`, `<.icon>`, `to_form/2`, and LiveView streams where they fit.
- Keep Vue components under `assets/vue`; LiveView remains the source of truth.
- Durable behavior changes should update the nearest subsystem README in the same change.
- Multi-step work should create or update a plan under `docs/plans/active/`.
