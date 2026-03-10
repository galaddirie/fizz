# Fizz Sprites Broker

`Fizz.Sprites` is the workspace-scoped broker for remote execution environments.

## Owns

- local sprite records and remote provisioning metadata
- exec jobs, persisted log chunks, checkpoints, and service state
- console session lifecycle
- background reconciliation and cleanup workers
- workspace UI for sprite inspection and operations

## Does Not Own

- workspace authorization and tenant resolution
  - See [lib/fizz/accounts/README.md](../accounts/README.md)
- provider credential storage
  - See [lib/fizz/accounts/README.md](../accounts/README.md)
- workflow runtime and step execution
  - See [lib/fizz/workflows/README.md](../workflows/README.md)

## Module Map

- [lib/fizz/sprites.ex](../sprites.ex)
  - Public broker API for provisioning, reconfiguration, jobs, consoles, checkpoints, and services.
- [lib/fizz/sprites/client.ex](client.ex)
  - External API client for the remote sprites service.
- [platform-overview.md](platform-overview.md)
  - Background on the external Sprites platform, checkpoint model, wake behavior, and why it fits agentic workspaces.
- [lib/fizz/sprites/workers](workers)
  - Oban workers for exec job processing and cleanup.
- [lib/fizz/integrations.ex](../integrations.ex)
  - Provider auth resolution used by sprite workflows that need external APIs.
- [lib/fizz_web/live/sprites_live](../../fizz_web/live/sprites_live)
  - Authenticated UI for listing sprites and operating on a single sprite.
- [assets/js/hooks/sprite_console.js](../../../assets/js/hooks/sprite_console.js)
  - Client-side console hook used by the sprite show page.

## Common Flows

### Provision a sprite

1. [SpritesLive.Index](../../fizz_web/live/sprites_live/index.ex) or other callers submit sprite details.
2. [Fizz.Sprites.provision_sprite/3](../sprites.ex) creates the local record and provisions the remote environment.
3. The broker stores restrictive defaults and emits telemetry.

### Run a job

1. [SpritesLive.Show](../../fizz_web/live/sprites_live/show.ex) queues the command.
2. [Fizz.Sprites.queue_job/4](../sprites.ex) persists the job and enqueues the worker.
3. [ExecJobWorker](workers/exec_job_worker.ex) streams output into persisted log chunks.

### Open a console

1. [SpritesLive.Show](../../fizz_web/live/sprites_live/show.ex) opens the console session.
2. [Fizz.Sprites.open_console/4](../sprites.ex) creates the broker-side session.
3. [sprite_console.js](../../../assets/js/hooks/sprite_console.js) bridges terminal events between the browser and the channel layer.

## Read this first

- [lib/fizz/sprites.ex](../sprites.ex)
- [lib/fizz_web/live/sprites_live/show.ex](../../fizz_web/live/sprites_live/show.ex)
- [lib/fizz/sprites/client.ex](client.ex)
- [lib/fizz/sprites/workers/exec_job_worker.ex](workers/exec_job_worker.ex)

## Read this next

- [platform-overview.md](platform-overview.md)
