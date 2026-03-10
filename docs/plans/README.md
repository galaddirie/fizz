# Plans

Plans are the repo's executable memory for multi-step work.

## When To Create One

Create or update a plan when work:

- crosses subsystem boundaries
- is expected to span multiple commits or sessions
- has important unknowns, tradeoffs, or rollout steps
- needs a durable checklist for verification or follow-up

## How To Use Plans

1. Copy [TEMPLATE.md](TEMPLATE.md) into [active](active/).
2. Keep the checklist current while work is in flight.
3. Record the commands, tests, and files that matter.
4. Move the file to [completed](completed/) when done.

## Directory Layout

- [active/](active/)
  - Ongoing implementation plans.
- [completed/](completed/)
  - Finished plans with outcomes and verification notes.
- [TEMPLATE.md](TEMPLATE.md)
  - Starting point for new plans.

## Example

- [2026-03-10-harness-adoption.md](completed/2026-03-10-harness-adoption.md)
