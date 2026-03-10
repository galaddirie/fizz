# Plan: harness-adoption

- Status: completed
- Owner: Codex
- Last Updated: 2026-03-10

## Goal

Adopt lightweight harness engineering practices for the Fizz repo by turning the root agent instructions into a routing layer, adding durable subsystem maps, and establishing executable plans inside the repo.

## Constraints

- Keep the root `AGENTS.md` short enough to function as a map.
- Preserve Phoenix and LiveView conventions that matter for safe edits.
- Prefer repo-local docs over another large policy file.

## Affected Areas

- `AGENTS.md`
- `README.md`
- `ARCHITECTURE.md`
- `docs/harness`
- `docs/plans`
- `lib/fizz/accounts/README.md`
- `lib/fizz/workflows/README.md`
- `lib/fizz/sprites/README.md`
- `lib/fizz/steps/executors/README.md`
- `lib/fizz_web/live/README.md`
- `mix.exs`
- `Taskfile.yml`

## Checklist

- [x] Inspect the owning code and nearest docs.
- [x] Implement the code changes.
- [x] Update the relevant README or architecture docs.
- [x] Run focused verification.
- [x] Run `mix precommit`.

## Commands

- `mix precommit`

## Notes

- This first pass focuses on repo structure, plans, and durable subsystem maps.
- CI can be layered on top later once the team wants the same guardrails on pull requests.

## Outcome

Fizz now has a short root agent map, durable subsystem docs near the owning code, and an executable plans workflow.
