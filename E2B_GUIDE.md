# E2B Self-Hosted + Elixir Implementation Guide

> A practical guide for engineering teams building a self-hosted E2B sandbox environment managed by an Elixir/OTP application.

---

## 1. Overview

This guide walks through the end-to-end implementation of a self-hosted E2B environment — from infrastructure provisioning to a production-hardened Elixir integration layer. E2B provides open-source infrastructure for executing untrusted code inside Firecracker microVMs (~150ms boot time, <5 MiB memory per VM). Elixir's OTP primitives (GenServer, DynamicSupervisor, Registry) provide the ideal management plane for orchestrating these sandboxes at scale.

### Architecture at a Glance

```
┌─────────────────────────────────────────────────────┐
│  Elixir Application (BEAM Cluster)                  │
│  ┌───────────┐  ┌────────────┐  ┌────────────────┐  │
│  │ Dynamic   │──│ GenServer  │──│ gRPC Channel   │  │
│  │ Supervisor│  │ (per sandbox)│ │ (to envd)      │  │
│  └───────────┘  └────────────┘  └───────┬────────┘  │
│        │              │                  │           │
│  ┌─────┴─────┐  ┌─────┴─────┐           │           │
│  │ Registry  │  │ Telemetry │           │           │
│  └───────────┘  └───────────┘           │           │
└─────────────────────────────────────────┼───────────┘
                                          │ gRPC/TLS
┌─────────────────────────────────────────┼───────────┐
│  E2B Infrastructure                     │           │
│  ┌──────┐  ┌────────┐  ┌───────────────▼─────────┐ │
│  │Nomad │──│Consul  │──│ Firecracker microVM     │ │
│  │      │  │        │  │  ┌─────┐  ┌───────────┐ │ │
│  └──┬───┘  └────────┘  │  │envd │  │Guest OS   │ │ │
│     │                   │  │:50051│  │(code exec)│ │ │
│  ┌──┴───┐               │  └─────┘  └───────────┘ │ │
│  │Redis │  ┌──────────┐ └─────────────────────────┘ │
│  │      │  │PostgreSQL│                              │
│  └──────┘  └──────────┘                              │
└──────────────────────────────────────────────────────┘
```

### Key Technology Decisions

| Component | Technology | Rationale |
|---|---|---|
| Virtualization | Firecracker VMM | Minimal device model, fast boot, small attack surface |
| Host Interface | KVM | Hardware-accelerated virtualization on Linux |
| In-VM Agent | envd (gRPC on :50051) | Filesystem + process management inside the guest |
| Orchestration | Nomad | Lightweight scheduling for non-containerized microVM workloads |
| Service Discovery | Consul | Dynamic endpoint resolution for ephemeral VMs |
| Fast State | Redis | Ephemeral lifecycle state transitions |
| Persistent State | PostgreSQL | Templates, API keys, audit logs |
| IaC | Terraform | Reproducible multi-cloud provisioning |
| Observability | OpenTelemetry | Vendor-agnostic tracing, metrics, and logs |

---

## 2. Prerequisites

Before starting, ensure the following:

- **Host hardware**: Bare-metal Linux servers (strongly recommended) or cloud instances with nested virtualization support (AWS `.metal`, specific GCP shapes). Bare metal provides ~1.8x faster random I/O and ~50% lower latency vs nested virtualization.
- **KVM access**: The host kernel must have the KVM module loaded (`/dev/kvm` must exist).
- **Tooling installed**: Terraform, Nomad, Consul, Docker (for builds), `protoc` with `protoc-gen-elixir`.
- **Elixir environment**: Elixir 1.15+, Erlang/OTP 26+, with `grpc-elixir`, `telemetry`, and `opentelemetry` dependencies.

---

## 3. Phase 1 — Infrastructure Provisioning

**Goal**: Deploy the E2B control plane and compute cluster.

### 3.1 Provision Compute Nodes

Using the Terraform scripts from the [e2b-dev/infra](https://github.com/e2b-dev/infra) repository (or the [aws-samples/sample-e2b-on-aws](https://github.com/aws-samples/sample-e2b-on-aws) fork for AWS):

```bash
# Clone the infrastructure repo
git clone https://github.com/e2b-dev/infra.git
cd infra

# Configure your provider (GCP, AWS, or bare-metal)
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your provider credentials, region, instance types

terraform init
terraform plan
terraform apply
```

**Key configuration choices:**
- Use bare-metal instances for latency-sensitive workloads.
- Size the cluster based on expected concurrent sandbox count (each microVM uses <5 MiB base + workload memory).
- Ensure the compute nodes are in a private subnet with no direct internet egress.

### 3.2 Deploy Nomad + Consul Cluster

Nomad handles scheduling microVM tasks; Consul handles service discovery. These are deployed as part of the Terraform scripts. Verify the cluster is healthy:

```bash
nomad server members
consul members
```

### 3.3 Deploy Supporting Services

- **Redis**: For ephemeral sandbox lifecycle state.
- **PostgreSQL**: For persistent metadata (templates, API keys).
- **OpenTelemetry Collector**: Deploy as a Nomad job to collect host and application metrics.
- **Prometheus + Grafana**: For dashboarding. Connect to the OTel collector.

### 3.4 Validate

- Confirm you can create a sandbox via the E2B API endpoint.
- Confirm the OTel collector is receiving metrics from compute nodes.
- Confirm Consul shows registered sandbox endpoints.

---

## 4. Phase 2 — Elixir Client Generation

**Goal**: Generate typed Elixir modules from E2B's Protocol Buffer definitions.

### 4.1 Obtain Proto Files

The envd service definitions (process management, filesystem operations) are in the [e2b-dev/infra](https://github.com/e2b-dev/infra) repository under the proto directory. These are the source of truth for all sandbox interactions.

### 4.2 Generate Elixir Stubs

Add dependencies to `mix.exs`:

```elixir
defp deps do
  [
    {:grpc, "~> 0.9"},
    {:protobuf, "~> 0.12"},
    # For proto compilation
    {:grpc_reflection, "~> 0.1"}
  ]
end
```

Generate the stubs:

```bash
# Install the protoc plugin
mix escript.install hex protobuf

# Generate Elixir modules from the E2B proto files
protoc \
  --elixir_out=gen_descriptors=true:./lib/e2b/proto \
  --grpc_out=./lib/e2b/proto \
  --plugin=protoc-gen-grpc=$(which grpc_elixir_plugin) \
  -I ./protofiles \
  ./protofiles/**/*.proto
```

This produces modules for RPC methods like process execution, filesystem read/write, and stream subscriptions.

### 4.3 Configure TLS for gRPC

All communication between the Elixir app and the envd daemon inside each microVM should use TLS (or mTLS in high-security environments):

```elixir
# In your application config
config :e2b_client,
  grpc_opts: [
    cred: GRPC.Credential.new(
      ssl: [
        cacertfile: "/path/to/ca.pem",
        certfile: "/path/to/client.pem",
        keyfile: "/path/to/client-key.pem"
      ]
    )
  ]
```

---

## 5. Phase 3 — OTP Management Layer

**Goal**: Build the GenServer-per-sandbox pattern with dynamic supervision and registry.

### 5.1 Supervision Tree Design

```
Application
└── E2B.SandboxSupervisor (DynamicSupervisor)
    ├── E2B.SandboxManager (GenServer) — sandbox_abc123
    ├── E2B.SandboxManager (GenServer) — sandbox_def456
    └── ...
```

### 5.2 The SandboxManager GenServer

Each GenServer encapsulates the full lifecycle of one sandbox:

```elixir
defmodule E2B.SandboxManager do
  use GenServer
  require Logger

  @idle_timeout :timer.minutes(5)

  defstruct [:sandbox_id, :grpc_channel, :status, :active_processes, :timer_ref]

  # --- Public API ---

  def start_link(opts) do
    template_id = Keyword.fetch!(opts, :template_id)
    GenServer.start_link(__MODULE__, opts, name: via(template_id))
  end

  def execute(sandbox_id, code, language) do
    GenServer.call(via(sandbox_id), {:execute, code, language}, 30_000)
  end

  def stop(sandbox_id) do
    GenServer.cast(via(sandbox_id), :stop)
  end

  # --- Callbacks ---

  @impl true
  def init(opts) do
    template_id = Keyword.fetch!(opts, :template_id)

    # Emit telemetry for sandbox creation
    :telemetry.execute([:sandbox, :creation, :start], %{}, %{template: template_id})

    case create_sandbox(template_id) do
      {:ok, sandbox_id, endpoint} ->
        {:ok, channel} = GRPC.Stub.connect(endpoint, grpc_opts())
        timer = Process.send_after(self(), :idle_timeout, @idle_timeout)

        :telemetry.execute([:sandbox, :creation, :stop], %{}, %{
          sandbox_id: sandbox_id,
          template: template_id
        })

        state = %__MODULE__{
          sandbox_id: sandbox_id,
          grpc_channel: channel,
          status: :ready,
          active_processes: %{},
          timer_ref: timer
        }

        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:execute, code, language}, from, state) do
    # Reset idle timer
    Process.cancel_timer(state.timer_ref)
    timer = Process.send_after(self(), :idle_timeout, @idle_timeout)

    # Spawn async task for execution to avoid blocking the mailbox
    Task.start(fn ->
      result = do_execute(state.grpc_channel, code, language)
      GenServer.reply(from, result)
    end)

    {:noreply, %{state | timer_ref: timer}}
  end

  @impl true
  def handle_cast(:stop, state) do
    cleanup(state)
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(:idle_timeout, state) do
    Logger.info("Sandbox #{state.sandbox_id} idle — shutting down")
    cleanup(state)
    {:stop, :normal, state}
  end

  # --- Private ---

  defp via(id), do: {:via, Registry, {E2B.SandboxRegistry, id}}

  defp create_sandbox(template_id) do
    # Call the E2B API (REST) to provision a new microVM
    # Returns {:ok, sandbox_id, "host:port"} or {:error, reason}
    E2B.API.create(template_id)
  end

  defp do_execute(channel, code, language) do
    :telemetry.execute([:sandbox, :execution, :start], %{}, %{language: language})
    # Use generated gRPC stubs to call envd
    result = E2B.Proto.ProcessService.Stub.execute(channel, %E2B.Proto.ExecRequest{
      code: code,
      language: language
    })
    :telemetry.execute([:sandbox, :execution, :stop], %{}, %{language: language})
    result
  end

  defp cleanup(state) do
    GRPC.Stub.disconnect(state.grpc_channel)
    E2B.API.terminate(state.sandbox_id)
  end

  defp grpc_opts do
    Application.get_env(:e2b_client, :grpc_opts, [])
  end
end
```

### 5.3 DynamicSupervisor and Registry

```elixir
defmodule E2B.Application do
  use Application

  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: E2B.SandboxRegistry},
      {DynamicSupervisor, name: E2B.SandboxSupervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

Starting a sandbox on demand:

```elixir
DynamicSupervisor.start_child(
  E2B.SandboxSupervisor,
  {E2B.SandboxManager, template_id: "python-data-science-v2"}
)
```

### 5.4 gRPC Stream Handling

For long-running executions that stream stdout/stderr, avoid blocking the GenServer mailbox. Spawn a dedicated consumer process:

```elixir
# Inside SandboxManager, for streaming output
defp stream_output(channel, process_id, subscriber_pid) do
  Task.start(fn ->
    stream = E2B.Proto.ProcessService.Stub.subscribe_output(channel, %{id: process_id})

    Enum.each(stream, fn
      {:ok, chunk} -> send(subscriber_pid, {:sandbox_output, chunk})
      {:error, reason} -> send(subscriber_pid, {:sandbox_error, reason})
    end)
  end)
end
```

Integrate with Phoenix.PubSub or LiveView for real-time UI updates.

### 5.5 Multi-Node Distribution

For clustered Elixir deployments, replace the local `Registry` with **Horde** for distributed registry and supervision:

```elixir
# In mix.exs
{:horde, "~> 0.9"},
{:libcluster, "~> 3.3"}
```

This enables "sticky" session management where any node can locate and interact with a sandbox managed on another node.

---

## 6. Phase 4 — Local Development Environment

**Goal**: Enable developers to iterate on the Elixir integration without a full production cluster.

### 6.1 Running Firecracker Locally

Firecracker requires KVM, so local development must happen on a Linux machine (or a Linux VM with nested virtualization enabled).

```bash
# Verify KVM is available
ls -la /dev/kvm

# Download Firecracker
ARCH=$(uname -m)
curl -L https://github.com/firecracker-microvm/firecracker/releases/latest/download/firecracker-v*-${ARCH}.tgz | tar xz

# Start a single microVM with the E2B rootfs and kernel
./firecracker --api-sock /tmp/firecracker.socket
```

Alternatively, use the E2B CLI to build and test custom templates locally:

```bash
npm install -g @e2b/cli
e2b template build --dockerfile ./Dockerfile.sandbox
```

### 6.2 Docker Compose for Infrastructure Services

For the supporting services (Redis, PostgreSQL, Consul, Nomad), use a local Docker Compose file:

```yaml
# docker-compose.dev.yml
version: "3.8"

services:
  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"

  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_DB: e2b_dev
      POSTGRES_USER: e2b
      POSTGRES_PASSWORD: dev_password
    ports:
      - "5432:5432"

  consul:
    image: hashicorp/consul:1.17
    ports:
      - "8500:8500"
    command: agent -dev -client=0.0.0.0

  nomad:
    image: hashicorp/nomad:1.7
    ports:
      - "4646:4646"
    command: agent -dev -bind=0.0.0.0
    privileged: true
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
```

```bash
docker compose -f docker-compose.dev.yml up -d
```

### 6.3 Mock / Stub Mode for Non-Linux Developers

Developers on macOS or Windows (without KVM) can't run Firecracker directly. Provide a mock adapter that replaces real sandbox calls with local Docker containers or in-process stubs:

```elixir
# config/dev.exs
config :e2b_client,
  adapter: E2B.Adapter.Mock  # or E2B.Adapter.Docker

# lib/e2b/adapter/mock.ex
defmodule E2B.Adapter.Mock do
  @behaviour E2B.Adapter

  def create(_template_id) do
    sandbox_id = "mock-#{:rand.uniform(100_000)}"
    {:ok, sandbox_id, "localhost:50051"}
  end

  def execute(_channel, code, _language) do
    # Execute locally via System.cmd or a Docker container
    {output, 0} = System.cmd("python3", ["-c", code], stderr_to_stdout: true)
    {:ok, %{stdout: output, stderr: "", exit_code: 0}}
  end

  def terminate(_sandbox_id), do: :ok
end
```

### 6.4 Local Development Workflow

```
1. Start infra services      →  docker compose up -d
2. Start Elixir app          →  iex -S mix phx.server
3. Create a sandbox           →  E2B.SandboxManager.start_link(template_id: "base")
4. Execute code               →  E2B.SandboxManager.execute("sandbox_id", "print('hello')", "python")
5. Observe telemetry          →  Check console logs or local Grafana at localhost:3000
6. Iterate on GenServer logic →  Hot-reload with `recompile()` in IEx
```

### 6.5 Integration Testing

Write tests against the mock adapter for CI, and tagged integration tests against a real local Firecracker instance:

```elixir
# test/e2b/sandbox_manager_test.exs
defmodule E2B.SandboxManagerTest do
  use ExUnit.Case, async: true

  @tag :integration
  test "executes Python code in a real sandbox" do
    {:ok, pid} = DynamicSupervisor.start_child(
      E2B.SandboxSupervisor,
      {E2B.SandboxManager, template_id: "base"}
    )

    assert {:ok, %{stdout: "42\n"}} =
      E2B.SandboxManager.execute("base", "print(6 * 7)", "python")
  end

  test "executes code via mock adapter" do
    # Uses the mock adapter configured in config/test.exs
    {:ok, pid} = start_supervised({E2B.SandboxManager, template_id: "base"})
    assert {:ok, %{stdout: _}} = E2B.SandboxManager.execute("base", "print(1)", "python")
  end
end
```

Run with:

```bash
# Unit/mock tests (CI-safe, no KVM needed)
mix test --exclude integration

# Full integration tests (requires Linux + KVM)
mix test --only integration
```

---

## 7. Phase 5 — Observability and Monitoring

**Goal**: Unified visibility across the Elixir app and the E2B infrastructure.

### 7.1 Instrument the Elixir Layer

Add dependencies:

```elixir
{:telemetry, "~> 1.2"},
{:opentelemetry, "~> 1.4"},
{:opentelemetry_api, "~> 1.3"},
{:opentelemetry_exporter, "~> 1.7"}
```

Attach telemetry handlers that convert events into OTel spans/metrics:

```elixir
# Events to instrument:
# [:sandbox, :creation, :start]  / [:sandbox, :creation, :stop]
# [:sandbox, :execution, :start] / [:sandbox, :execution, :stop]
# [:sandbox, :grpc, :error]
```

Export to the same OTel collector used by the E2B infrastructure, enabling end-to-end traces from a Phoenix request → LLM call → sandbox code execution.

### 7.2 Key Dashboards

| Dashboard | Metrics |
|---|---|
| Cluster Health | Node CPU/memory, Nomad allocation count, Consul service health |
| Sandbox Lifecycle | Creation p50/p99 latency, active sandbox count, idle timeouts |
| Execution Performance | Code execution latency by language, error rate, stream throughput |
| Elixir App | GenServer mailbox depth, process count, BEAM scheduler utilization |

---

## 8. Phase 6 — Security Hardening

**Goal**: Lock down the system for production use with untrusted AI-generated code.

### 8.1 Sandbox Isolation (Firecracker + Jailer)

Each microVM is wrapped by the Jailer, which enforces:
- **Namespaces**: Isolate from host network, filesystem, PID tree
- **Chroot**: Restrict filesystem view to an empty directory
- **Cgroups**: CPU and memory limits to prevent DoS
- **Seccomp**: Restrict allowed syscalls for the VMM process

### 8.2 Network Policies

- Sandboxes run in a private network with **no direct internet access** by default.
- If outbound access is needed, route through a secure proxy with allowlists and traffic logging.
- Sandbox-to-sandbox communication is blocked.

### 8.3 Filesystem Permissions

- Use consistent UID/GID in sandbox templates so envd and user code run in the same context.
- After uploading files via the filesystem API, explicitly set permissions (`chmod`/`chown`).
- Prefer rootless execution to minimize impact of guest escape.

### 8.4 Elixir Application Security

- Store E2B API keys in `runtime.exs` or a secrets manager — never in source control.
- Enforce TLS/mTLS on all gRPC connections to envd.
- Rate-limit sandbox creation per user/session.

---

## 9. Performance Tuning

### 9.1 Host Selection

| Metric | Bare Metal | Nested Virtualization | Recommendation |
|---|---|---|---|
| Random I/O | ~1.8x faster | Baseline | Use BM for data-heavy workloads |
| I/O Latency | ~50% lower | Baseline | Use BM for latency-sensitive apps |
| CPU Overhead | Baseline | ~3% overhead | Either is acceptable for compute |
| Memory BW | Baseline | ~11% overhead | Negligible for most use cases |

### 9.2 Template Optimization

Reduce perceived cold start by building "pre-warmed" custom templates:

- **Pre-install packages**: Bake Python/Node.js libraries into the rootfs image. Avoid runtime `pip install`.
- **Custom start commands**: Pre-initialize services and environment variables in the template.
- **Minimal guest OS**: Use Alpine or stripped Debian for a smaller boot payload.

### 9.3 Elixir-Side Optimization

- Maintain a **template ID cache** in the Elixir app to skip lookups during sandbox dispatch.
- Use **sandbox pooling** for burst workloads: pre-create a pool of idle sandboxes and assign them on demand.
- Tune GenServer idle timeouts based on actual usage patterns.

---

## 10. Checklist

### Phase 1 — Infrastructure
- [ ] Provision compute nodes (bare metal preferred)
- [ ] Deploy Nomad + Consul cluster
- [ ] Deploy Redis, PostgreSQL
- [ ] Deploy OTel collector + Prometheus/Grafana
- [ ] Validate sandbox creation via API

### Phase 2 — Client Generation
- [ ] Obtain E2B `.proto` files
- [ ] Generate Elixir gRPC stubs with `protoc-gen-elixir`
- [ ] Configure TLS certificates for gRPC

### Phase 3 — OTP Layer
- [ ] Implement `SandboxManager` GenServer
- [ ] Set up `DynamicSupervisor` + `Registry`
- [ ] Implement gRPC stream handling for stdout/stderr
- [ ] (Optional) Add Horde for multi-node distribution

### Phase 4 — Local Dev
- [ ] Docker Compose for local infra services
- [ ] Mock adapter for non-Linux developers
- [ ] Integration test suite with `@tag :integration`

### Phase 5 — Observability
- [ ] Instrument telemetry events for sandbox lifecycle
- [ ] Export to OTel collector
- [ ] Build Grafana dashboards

### Phase 6 — Security
- [ ] Verify Jailer configuration on all compute nodes
- [ ] Enforce network isolation and proxy rules
- [ ] Configure TLS/mTLS for gRPC
- [ ] Secrets management for API keys
- [ ] Filesystem permission audit on templates