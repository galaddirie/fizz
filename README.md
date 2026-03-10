# Fizz

Fizz is a Phoenix application for workspace-scoped workflow automation. The repo is split across three main areas: accounts and tenancy, the workflow engine, and the Sprites broker for remote execution.

## Quick Start

- Run `mix setup` to install dependencies, set up the database, and build assets.
- Start Phoenix with `mix phx.server` or `iex -S mix phx.server`.
- Visit [localhost:4000](http://localhost:4000).
- Run `mix precommit` before handing changes off.

## Repo Guide

- [AGENTS.md](AGENTS.md)
- [ARCHITECTURE.md](ARCHITECTURE.md)
- [docs/harness/README.md](docs/harness/README.md)
- [docs/plans/README.md](docs/plans/README.md)

## Subsystem Maps

- [lib/fizz/accounts/README.md](lib/fizz/accounts/README.md)
- [lib/fizz/workflows/README.md](lib/fizz/workflows/README.md)
- [lib/fizz/sprites/README.md](lib/fizz/sprites/README.md)
- [lib/fizz/steps/executors/README.md](lib/fizz/steps/executors/README.md)
- [lib/fizz_web/live/README.md](lib/fizz_web/live/README.md)

## Learn More

- [Phoenix website](https://www.phoenixframework.org/)
- [Phoenix guides](https://hexdocs.pm/phoenix/overview.html)
- [Phoenix docs](https://hexdocs.pm/phoenix)
