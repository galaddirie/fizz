# Sprites Platform Overview

This document explains the external Sprites platform that powers Fizz's sprite broker.

Read [README.md](README.md) in this directory first for the Fizz-owned module map and entry points. Read this file second when you need the platform mental model, checkpointing semantics, or product rationale behind Sprites.

## Sprites in one sentence

**Sprites are “disposable computers” (hardware-isolated microVMs) where *persistent disk state* and *checkpoint/restore* are the default ergonomics—so you can spin up a fresh Linux environment in ~seconds, do risky work, and roll back as casually as `git restore`.** ([Fly][1])

They’re built on Fly.io’s Firecracker-based microVM infrastructure (strong hardware virtualization isolation), but with several design choices that *invert* the usual cloud VM/container assumptions. ([Fly][2])

---

# How Sprites redefine “virtual machines”

Traditional VMs and containers treat **compute** as primary and **state** as something you bolt on (volumes, external DBs, object stores, caches, snapshots, backups, image registries, CI pipelines).

Sprites treat **stateful execution environments** as the primitive:

* A Sprite is a Linux environment you can mutate freely (install tools, clone repos, run databases, write files).
* It aggressively sleeps when idle to drive compute cost toward ~0 while retaining the environment on disk. ([Fly][1])
* Wake-up is designed to feel like “it was already there.” Warm wakes are ~100–500ms; cold wakes are ~1–2s. ([Sprites Documentation][3])

That combination shifts what “a VM” *means* in practice: less “pet server you babysit” or “cattle instance you rebuild,” and more **a stateful, forkable workspace** you can throw away or rewind without fear.

---

## 1) Persistent state as a first-class primitive

### What persists

Sprites have a **persistent ext4 filesystem** and are meant to keep your environment intact across runs/hibernation—packages, files, repos, and databases on disk persist. ([Sprites Documentation][4])

Under the hood, Fly’s design makes this practical at scale:

* During execution, writes go to fast local NVMe.
* When idle, that state is backed by durable S3-compatible object storage and restored when waking. ([Sprites Documentation][4])
* Fly explicitly calls out that Sprites default to **100GB durable root filesystems** because the root of storage is object storage. ([Fly][1])

### What *doesn’t* persist (important nuance)

**RAM and running processes do not persist across hibernation**—processes stop, in-memory data is lost, and you should arrange auto-restarts for anything that must come back on wake. ([Sprites Documentation][3])

This is a key mental model for agentic workflows:

* You persist *tools + repos + caches + artifacts + DB files* on disk.
* You rehydrate *runtime memory* via startup scripts/services.

### Why this is redefining

In a normal container-first world, the “correct” workflow is: rebuild an image, redeploy, keep state outside. Sprites flip it: **mutate the environment directly, keep it, and checkpoint it**—more like a personal computer, but programmable and isolated.

---

## 2) “Infinite sprites” and checkpoint-based execution (the real unlock)

The “infinite sprites” idea is not literally infinite compute—it’s that **you can treat whole Linux machines as cheap, abundant, on-demand objects**:

* Fly says you can create “a couple dozen Sprites” and it “only takes a second.” ([Fly][1])
* They get rid of the *user-facing* container image workflow and standardize the base container internally so workers can keep pools of “empty” Sprites ready. That’s how `create` becomes “basically just start a machine.” ([Fly][1])

### Checkpoint/restore as *workflow*, not disaster recovery

Sprites make checkpoint/restore feel like a *core interaction*, not a last resort:

* You can snapshot the filesystem, then restore later (with warnings: restoring replaces the entire filesystem; checkpoints count against storage; creation takes time proportional to data). ([Sprites Documentation][3])
* Fly’s engineering post emphasizes that checkpoint/restore is designed to be fast enough to be “like a git restore, not a system restore,” because the platform can treat it as largely metadata shuffling (their storage stack uses immutable chunks and metadata moves). ([Fly][1])

### What “checkpoint-based execution” means for agents

Instead of “run code → hope nothing broke → rebuild if it did,” you can structure workflows as:

1. **Start from a known-good checkpoint**
2. Execute a risky step (dependency upgrade, tool install, codegen + tests, migration dry run, scraping run, etc.)
3. If it worked, checkpoint again (promote state). If not, **rollback instantly** (revert state). ([Sprites Documentation][3])

That’s what you meant by *running work fearlessly*: the *environment* becomes versionable.

---

## 3) Near-zero startup latency (why it feels different from “fast VMs”)

Sprites target two latencies:

### A) **Creation latency** (getting a new machine)

Fly claims Sprite `create` is “just a second or two,” and that it feels like SSH’ing into a machine that already exists. ([Fly][1])
They can do that because they removed the user-facing “pull arbitrary OCI image” path and instead pre-position a standard base runtime on workers. ([Fly][1])

### B) **Wake latency** (getting back to work)

Warm wakes are ~100–500ms; cold wakes ~1–2s, and HTTP requests can wake a Sprite automatically. ([Sprites Documentation][3])

**Compare to traditional patterns:**

* *Containers*: fast to start **if** the image is local and small; slow if images are large or cold on the node; and state is usually external.
* *VMs*: slower boot, heavier orchestration, and persistent disks often tie you to a host/zone or require complex networked storage.
* *Serverless*: great cold starts sometimes, but you usually don’t keep a mutable full Linux workspace + durable filesystem between invocations.

Sprites land in a new spot: **serverless-like wake + VM-like isolation + workstation-like mutability**, with state persistence as the default. ([Sprites Documentation][4])

---

## 4) Instant checkpointing and rollbacks (and why this is plausible)

Two important layers:

### User-facing checkpointing

From the CLI perspective, you do:

* `sprite checkpoint create`
* `sprite checkpoint list`
* `sprite restore <id>` ([Sprites Documentation][3])

This is “instant enough” to become a habit. The docs caution that checkpoint creation can take 10–30 seconds depending on data size (because the filesystem snapshot has to be materialized). ([Sprites Documentation][3])

### Storage architecture that makes frequent snapshots feasible

Fly’s design post explains the trick: durable state lives in **object storage**; NVMe is a cache; chunks are immutable; checkpoint/restore can often be reduced to **metadata moves**. ([Fly][1])

That design goal is exactly what unlocks “checkpoint like git commits” as a *normal* workflow.

---

# What new categories of applications this enables

## 1) Stateful agent workspaces (the “AI-native” killer app)

Agents aren’t just stateless request handlers—they accumulate:

* toolchains, SDKs, compilers
* cloned repos and working trees
* caches (pip/npm, model artifacts, build outputs)
* local DBs (SQLite, DuckDB), indexes, vector stores
* long-lived credentials (ideally via injected secrets), config, scratchpads

Sprites match that shape: full Linux + durable filesystem + rapid wake. ([Sprites Documentation][4])

**Example workflow:** each user (or each agent thread) gets a Sprite as “their computer.” The agent iterates over days, sleeping when idle, waking on the next event, with checkpoints before risky steps.

## 2) Secure “bring your own runtime” code execution APIs

If you run user-submitted code, you usually fight:

* isolation (containers are often “good enough” but not always)
* per-language toolchains
* cold start/image churn
* state capture for debugging or replay

Sprites are explicitly positioned for “running arbitrary code safely” with hardware isolation and persistent environments. ([Sprites Documentation][4])

A powerful pattern here is: **reproducible sandboxes**

* A failed run becomes a checkpoint you can restore and inspect.
* You can hand the exact environment to a human or another agent.

## 3) Long-lived services that are idle most of the time

If you have services that get sporadic traffic (admin tools, internal dashboards, one-off webhook processors), Sprites’ auto-sleep + wake-on-request changes the economics—no need to keep a container warm 24/7. ([Sprites Documentation][3])

## 4) “Disposable dev environments” and ephemeral CI with real state

Instead of rebuilding CI environments from scratch:

* Use a Sprite as a persistent runner that keeps tool caches and dependencies.
* Checkpoint before major upgrades.
* Fork a fresh Sprite per PR/test batch.

Fly even frames Sprites as ideal for prototyping/acceptance-testing before containerizing for scale-out production. ([Fly][1])

---

# What infrastructure constraints Sprites remove (or dramatically reduce)

## Container image + registry friction (build/push/pull as the bottleneck)

Fly calls out that a “heartbreaking amount of engineering work” goes into OCI registry performance at scale, and Sprites sidestep the *user-facing* container image problem by standardizing the base. ([Fly][1])

**Implication:** for agent workflows, you stop paying the “container tax” (build pipelines, multi-arch images, layer churn) just to run a mutated environment.

## “Externalize all state” as a mandatory architecture rule

The container-native mantra is: stateless compute, state in managed services. That’s often correct for large-scale web serving—but it’s hostile to interactive, exploratory, tool-heavy workflows.

Sprites let you keep a *workspace-shaped* state locally on disk (repos, caches, DB files) without immediately designing a production-grade distributed persistence layer. ([Sprites Documentation][4])

## Risky changes become reversible

In normal cloud setups, you avoid fear by:

* immutable images
* staging/prod promotion flows
* heavy CI gates
* infra-as-code rollbacks

With Sprites, you get a second axis: **environment checkpoints**. The rollback unit is a whole filesystem snapshot. ([Sprites Documentation][3])

This doesn’t replace disciplined release engineering for high-scale production—but it removes huge friction for agentic workflows, prototyping, and personalized per-user compute.

## “Orchestrator blast radius” is reduced (inside-out orchestration)

Fly’s design emphasizes that Sprites push a lot of orchestration and management *inside the VM*, behind an “inner container,” so platform changes don’t require restarting host components and the blast radius is constrained to new VMs picking up changes. ([Fly][1])

For builders, the takeaway is: **Sprites are engineered to scale operationally as a fleet of tiny, user-specific computers**, not as a traditional app deployment substrate.

---

# Why this model is unusually aligned with AI-native systems

AI-native apps often look like this:

* An agent loop (plan → act → observe) that spans minutes to days
* Tool installation and rapid environment mutation
* Long-running context stored as artifacts (files, notes, partial outputs)
* Frequent “oops” moments (bad dependency install, destructive command, corrupted repo)
* Security boundaries (run generated code, possibly untrusted)

Sprites map cleanly:

* **Persistent workspace** for the agent (disk state survives). ([Sprites Documentation][4])
* **Rapid wake** so the agent can be “always available” without always billing. ([Sprites Documentation][3])
* **Hardware isolation** for untrusted code execution. ([Fly][2])
* **Checkpoint/restore** as the safety harness that lets agents operate aggressively. ([Fly][1])

In other words: Sprites make “agent = a computer” literal.

---

# What sorts of products you can build on Sprites (concrete ideas)

## A) Stateful agentic workflow apps (your stated target)

**Product shape:** “Workspaces” that are actually Sprites, one per user / project / agent instance.

Capabilities:

* “Open workspace” wakes the Sprite and attaches a web UI.
* Agent runs tasks inside the Sprite via exec/session APIs.
* The app checkpoints automatically before risky phases (dependency install, migrations, refactors). ([Sprites Documentation][3])

Examples:

* AI coding workspace (per user repo + toolchain + preview server)
* Data analysis agent (keeps datasets + notebooks + DuckDB)
* Security research sandbox (malware analysis / untrusted binaries, with strict networking policies via API) ([Sprites][5])

## B) “Fearless automation” platforms

Think: Zapier/n8n-style workflows, but each workflow has a persistent Linux environment.

* Steps can install tools and keep them.
* Retries don’t start from zero.
* Rollback is a restore to checkpoint.

This enables workflows that currently feel too brittle to automate (multi-step toolchains, flaky CLIs, complex environment assumptions).

## C) Reproducible bug reports + customer support sandboxes

“Send us a snapshot” becomes real:

* Capture a checkpoint when the bug happens.
* Support (human or agent) restores the exact environment and investigates.

## D) Per-customer “personalized SaaS”

Fly hints at “malleable, personalized apps” being a direction. Sprites make per-user compute economically plausible when idle costs are near-zero. ([Fly][1])

---

# Comparisons (VMs vs containers vs serverless vs Sprites)

| Dimension             | Traditional VM                    | Containers                  | Serverless functions    | **Sprites**                                                                     |
| --------------------- | --------------------------------- | --------------------------- | ----------------------- | ------------------------------------------------------------------------------- |
| Isolation             | Strong (hypervisor)               | Weaker (namespaces/cgroups) | Usually container-based | **Strong hardware isolation (microVM)** ([Fly][2])                              |
| Mutable “workspace”   | Yes                               | Sometimes, but discouraged  | No                      | **Yes (full Linux)** ([Sprites Documentation][4])                               |
| Persistent local disk | Yes (but often host/zone-coupled) | Usually external volume     | Usually no              | **Yes; ext4 + object-store durability** ([Sprites Documentation][4])            |
| Startup/wake          | Slow-ish boots                    | Fast if image local         | Cold starts vary        | **Warm wake ~100–500ms; cold ~1–2s; create ~1–2s** ([Sprites Documentation][3]) |
| Rollback              | Snapshots (heavy)                 | Rebuild/redeploy            | Redeploy                | **Checkpoint/restore designed to be frequent** ([Fly][1])                       |
| Best fit              | Long-running services             | Scaled web apps             | Event handlers          | **Stateful sandboxes + agent workspaces** ([Sprites Documentation][4])          |

---

# Implications for the future of cloud computing

## 1) “Stateful serverless” stops being a contradiction

Sprites are essentially: **pay-per-use compute + persistent per-instance environment**. That’s a new default for interactive and agentic systems.

## 2) The unit of deployment shifts from “app artifact” to “environment artifact”

Containers made the artifact the image.
Sprites make the artifact the *checkpointed environment*.

For AI-driven development, that is a big deal: agents don’t just deploy code; they **accrete state** (tools, caches, partial results). Environment snapshots become a first-class output.

## 3) Object storage becomes the “real disk,” NVMe becomes cache

Fly is explicit: durable state lives in S3-compatible storage; NVMe is a caching layer; immutable chunks + metadata management make restore/rollback fast. ([Fly][1])

That’s a broader architectural direction: treat object storage as the system of record even for VM disks—something the industry has wanted, but struggled to make fast enough for general workloads.

---

# Practical guide: working with Sprites (for stateful agentic workflow apps)

## Mental model

* **Sprite = persistent Linux box**
* **Sleep/wake happens automatically**
* **Disk persists; RAM does not**
* **Use services for anything that must come back on wake** ([Sprites Documentation][3])

## CLI essentials

Create and select:

```bash
sprite create
sprite use my-sprite
sprite list
sprite destroy -s my-sprite
```

([Sprites Documentation][6])

Run commands:

```bash
sprite exec ls -la
sprite console
```

Use TTY sessions for long-running interactive work and detach with `Ctrl+\`. ([Sprites Documentation][3])

## Keeping processes alive across sleep: Services

If you need a server/daemon to restart whenever the Sprite wakes, register it as a service:

```bash
sprite-env services create my-server --cmd node --args server.js
```

Services survive hibernation; ad-hoc TTY sessions do not. ([Sprites Documentation][3])

## Networking

Every Sprite can have an HTTP URL; requests can wake it. You can also port-forward TCP connections for private ports.

```bash
sprite url
sprite url update --auth public   # be careful
sprite proxy 5432
sprite proxy 3001:3000
```

([Sprites Documentation][3])

## Checkpointing patterns (the “fearless work” loop)

### Manual “git-style” checkpoints

Before any risky operation:

```bash
sprite checkpoint create --comment "before dependency upgrade"
```

List and restore:

```bash
sprite checkpoint list
sprite restore <id>
```

Restoring replaces the entire filesystem; changes since checkpoint are lost. ([Sprites Documentation][3])

### Recommended agent workflow

1. Start from a known checkpoint like “clean base”
2. Run a bounded agent task (upgrade, refactor, generate code)
3. Run tests / validations
4. If pass → checkpoint “task complete”
5. If fail → restore “clean base” and try another approach

This makes agent iteration *safe by default*.

## Mounting a Sprite locally (when you want IDE-native workflows)

Sprites don’t expose SSH directly, but the docs show a pattern:

* Install SSH server inside the Sprite
* Tunnel it through `sprite proxy`
* Mount using SSHFS ([Sprites Documentation][3])

That gives you “edit locally, execute remotely” ergonomics—useful if your product wants to offer a local-dev bridge.

## Using the API/SDKs in your product

Sprites provide an API with endpoints for:

* create/list/destroy sprites
* exec sessions (HTTP + WebSocket)
* checkpoints and restore
* services management
* filesystem operations (read/write/list/watch)
* network policy controls ([Sprites][5])

This is exactly what you need for an agentic workflow app:

* Your orchestrator calls `create_sprite`
* Your agent runner calls `exec` and streams output
* Your safety layer triggers `checkpoint`/`restore`
* Your UI uses filesystem APIs to show diffs/artifacts

---

## A few “gotchas” for agent builders (learn these early)

* **Don’t assume in-memory continuity.** Persist progress to disk (task logs, JSON state, SQLite) and use services/startup scripts to rehydrate. ([Sprites Documentation][3])
* **Checkpoint size matters.** If your agent downloads huge models/datasets into the root FS, checkpoint creation will slow and storage costs rise. Use a deliberate layout (e.g., keep bulky caches in a directory you rarely checkpoint, or use separate Sprites for heavy assets). ([Sprites Documentation][3])
* **Treat restore as destructive to “latest state.”** It’s a hard revert of the filesystem, which is what makes it powerful. ([Sprites Documentation][3])
* **Use network controls for safety.** If you’re running untrusted/generated code, pair isolation with outbound controls via the API’s network policy features. ([Sprites][5])

---

If you tell me what your agentic workflow app is (coding agent? data agent? automation agent?) I can sketch a concrete reference architecture on Sprites: workspace lifecycle, checkpoint strategy, isolation model, and the minimal API surface you’d implement first.

[1]: https://fly.io/blog/design-and-implementation/ "The Design & Implementation of Sprites · The Fly Blog"
[2]: https://fly.io/docs/reference/architecture/ "The Fly.io Architecture · Fly Docs"
[3]: https://docs.sprites.dev/working-with-sprites/ "Working with Sprites | Sprites"
[4]: https://docs.sprites.dev/ "Sprites Overview | Sprites"
[5]: https://sprites.dev/api "Sprites API Documentation"
[6]: https://docs.sprites.dev/cli/commands/ "CLI Commands Reference | Sprites"
