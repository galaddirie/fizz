# Sprites: Persistent Sandboxed VMs

Sprites are lightweight, stateful Linux micro‑VMs designed for running arbitrary code with hardware-level isolation and persistence【7†L58-L63】. They function like tiny disposable computers you can spin up instantly. Unlike serverless functions, Sprites keep their full filesystem and memory between runs, waking from hibernation in ~100–500 ms【7†L71-L77】【10†L187-L195】. Key features include:

- **Persistent filesystem**: Each Sprite has a standard ext4 root disk (100 GB) backed by fast NVMe and object storage【7†L58-L63】【10†L295-L302】. All files, installed packages, databases, etc., survive restarts and idle hibernation【8†L170-L178】. You can install tools (`sprite exec pip install …`) and they remain available later【10†L295-L302】.  
- **Fast startup and idle**: Sprites auto‑sleep when inactive (in ~30 s) and wake on demand. A “warm” Sprite resumes almost instantly, while a “cold” Sprite takes ~1–2 s【10†L187-L195】. There are no CPU charges while a Sprite is asleep (per-second billing only)【7†L71-L77】. This means you can have many sprites in a pool without paying for idle compute.  
- **Full Linux environment**: Sprites run Ubuntu 24.04 LTS with common dev tools (Node.js, Python, Go, Elixir, etc.) preinstalled【10†L278-L283】. You can install any software or language runtime you need. In effect, each Sprite is a tiny reusable VM with root access.  
- **Hardware isolation**: Under the hood each Sprite is a Firecracker microVM, providing stronger isolation than a container【7†L71-L77】. This lets you safely execute untrusted code or provide user sandboxes without risking the host.  
- **HTTP and networking**: Every Sprite has its own unique URL (`https://<name>.sprites.app`) and built-in TLS【10†L222-L230】. By default the URL is private (requires a Bearer token), but you can make it public for demos or webhooks【10†L230-L239】. The URL automatically “wakes” the Sprite on request. You can also forward ports (e.g. `sprite proxy`) from the Sprite to localhost for database or SSH access.  
- **Services and sessions**: Long-lived processes should be created as a *Service* (via `sprite-env services create`) so they automatically restart whenever the Sprite wakes【10†L191-L200】. Interactive shells (tty sessions) and one-off `sprite exec` commands stop when the Sprite sleeps【10†L200-L202】. Use detachable TTY sessions or background Services for ongoing workloads.  
- **Checkpoints**: Sprites support instant snapshots. You can run `sprite checkpoint create` to snapshot the entire filesystem and memory, then `sprite restore` later. This lets you roll back or branch environments at will【10†L370-L379】. Checkpoints use object storage under the hood, so creating or restoring them is very fast (metadata shuffling).

Overall, Sprites behave like persistent, autoscaling VMs: they **sleep** to save costs and **resume** on demand, while preserving your entire environment【7†L58-L63】【10†L187-L195】. This makes them ideal for things like AI code execution, CI/CD tasks, user code sandboxes, or development environments【7†L83-L92】.

## Elixir SDK Integration

Fly.io provides an official Elixir client library (`:sprites`) for managing Sprites via the API【18†L288-L296】【18†L325-L334】. In your `mix.exs`, add:

```elixir
def deps do
  [{:sprites, git: "https://github.com/superfly/sprites-ex.git"}]
end
```

Then you can create a client and control Sprites from your Elixir code【18†L288-L296】. For example:

```elixir
client = Sprites.new(sprites_token, base_url: "https://api.sprites.dev")
{:ok, sprite} = Sprites.create(client, "tenant123-sprite")
{output, exit_code} = Sprites.cmd(sprite, "echo", ["hello"])
IO.puts(output)  # prints "hello\n"
```

This demonstrates the **synchronous** command API (`Sprites.cmd/4`) which waits for completion【18†L327-L334】. The SDK also supports **asynchronous** execution (like `Port` in Elixir) using `Sprites.spawn/3`. For example:

```elixir
{:ok, cmd_ref} = Sprites.spawn(sprite, "bash", ["-c", "ls"], tty: true)
receive do
  {:stdout, ^cmd_ref, data} -> IO.write(data)
  {:exit, ^cmd_ref, code} -> IO.puts("Exited: #{code}")
end
```

This lets you stream output or send input interactively【18†L347-L356】【18†L356-L364】. There’s even a streaming API (`Sprites.stream`) for piping command output into a `Stream` pipeline【18†L370-L375】. Under the hood, the Elixir SDK handles HTTP calls to the Sprites service, but from your code it feels like managing local processes.

## Building Multi-Tenant Elixir Apps with Sprites

In a multi-tenant architecture, you can treat each tenant (user or organization) as having one or more dedicated Sprites for isolation. The Fly.io community confirms that **spinning up Sprites programmatically for many users is a supported use case**【5†L31-L34】. In practice, you might:

- **Provision per-tenant sprites**: When a new tenant is created, your app can call `Sprites.create` (via the SDK) to provision a fresh Sprite named or tagged for that tenant. For example, use `"tenant42-sprite"` or include a unique ID in the name. The new Sprite starts as a clean Ubuntu VM where you can install tenant-specific tools or dependencies.  
- **Run tenant code in the sprite**: To execute actions on behalf of a tenant, use the SDK from your Elixir app to run commands in that tenant’s Sprite. This could be one-off scripts (`Sprites.exec`), interactive shells (`sprite console` via CLI), or spawning background processes. Because each Sprite is isolated, tenants cannot affect each other’s data or environment.  
- **Map routes or subdomains**: You can expose each sprite’s HTTP service via its unique URL (`tenant42-sprite.sprites.app`). In a Phoenix app, you could redirect tenant requests to the corresponding Sprite URL (setting `--auth public` if needed【10†L230-L239】). Alternatively, keep the Sprite private and proxy requests through your Elixir backend (e.g. using `sprite proxy`).  
- **Use persistent state**: Since the filesystem is persistent, any tenant-specific state (files, databases, builds) stays on the Sprite until deleted. You might initialize a Sprite with a database or clone a repo once, and all subsequent sessions will see the same state. This is useful for tenant-specific caches, compiled assets, or user workspaces.  
- **Manage lifecycle carefully**: Although Sprites auto-sleep, you may still want to destroy idle Sprites if a tenant is deactivated. Use `Sprites.destroy(sprite)` to clean up. Checkpoints can snapshot a tenant’s environment before risky changes, allowing rollbacks. The 100 GB storage is per-sprite, but you only pay for storage actually used【17†L599-L602】, so having many idle sprites typically costs very little.  

In summary, your multi-tenant Elixir service can treat each tenant’s sprite as their own sandboxed VM. Your Phoenix/OTP app uses the Sprites SDK (or CLI) to create, run, and manage these environments under the hood. Because Sprites are hardware-isolated microVMs, this pattern gives strong per-tenant isolation: each tenant’s code and data live in a separate VM. The Fly team notes that Sprites were **designed to support programmatically created environments for different users**【5†L31-L34】.

## Operational Considerations

When building on Sprites, keep these points in mind:

- **Cost model**: Sprites bill **per-second** of compute (not per-invocation) and do *not* charge while idle【7†L71-L77】. There is also a small storage cost for data stored in object storage, but Fly.io only bills you for the disk blocks you actually use【17†L599-L602】. In practice, a completely idle sprite costs essentially nothing. This makes it feasible to have many tenant sprites sleeping in the background, ready to wake up.  
- **Startup latency**: Waking a Sprite is very fast (hundreds of milliseconds). For web services, register long-running processes as **Services** (`sprite-env services create`) so they automatically restart on wake【10†L191-L200】. This way, an HTTP request will wake the Sprite and the service comes up quickly to handle it.  
- **Resource limits**: By default a Sprite provides up to 2 virtual CPUs and 8 GB RAM (Fly’s current defaults for Sprites). If your tenants need more compute or GPU, note that Sprites are CPU-only (GPUs require Fly Machines)【14†L85-L93】. Also, keep an eye on the 100 GB storage quota per sprite; clean up old files or checkpoints if you hit the limit【20†L0-L9】.  
- **Security**: Each Sprite is a fully isolated microVM. Default network egress is permitted, so you might restrict it using Sprites’ network policies if needed. The default URL auth is a bearer token, so tenants can only access their own sprite’s URL if you share the token appropriately. If exposing public endpoints, ensure only non-sensitive services are exposed (as the docs warn)【10†L230-L239】.  
- **Environment setup**: Since Sprites start with a clean base image, your Elixir app may need to automate installation of tenant dependencies. You can install packages via `Sprites.exec` (e.g. `Sprites.cmd(sprite, "npm", ["install", "..."])`), and they will persist. For reproducible builds, consider using checkpoints: create a checkpoint after setup (`sprite checkpoint create`) so new Sprites can clone that state.  
- **Monitoring and logs**: As with any VM, use `sprite exec` to inspect status (e.g. `ps`, `df`). The Sprites CLI/SDK currently doesn’t stream logs natively, but you can redirect service output to files or use external logging. Also monitor your Fly.io usage dashboard to track sprites and costs.  

By following these guidelines, you can leverage Sprites to build multi-tenant Elixir applications where each tenant runs code in its own secure, persistent VM. The combination of the Elixir SDK and Sprites’ unique features (persistent storage, instant wake, hardware isolation) allows you to offload sandboxing complexity to Fly’s platform. In practice, this means your Elixir code simply orchestrates sprites for each tenant, while Fly.io handles the underlying VM orchestration, scaling, and isolation【7†L58-L63】【5†L31-L34】.

**Sources:** Official Sprites documentation and Elixir SDK examples【7†L58-L63】【18†L288-L296】; Fly.io community discussion【5†L31-L34】; working with sprites guide【10†L191-L200】【10†L230-L239】.


