defmodule Fizz.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      []
      |> maybe_add_child(
        {NodeJS.Supervisor, [path: LiveVue.SSR.NodeJS.server_path(), pool_size: 4]},
        Application.get_env(:live_vue, :ssr, true)
      )
      |> Kernel.++([
        FizzWeb.Telemetry,
        Fizz.Repo,
        Fizz.Workflows.LeaseManager,
        {Fizz.Workflows.Store.LitestreamManager,
         data_dir: Application.get_env(:fizz, :workflow_data_dir),
         s3_bucket: Application.get_env(:fizz, :litestream_s3_bucket),
         s3_prefix: Application.get_env(:fizz, :litestream_s3_prefix),
         aws_region: Application.get_env(:fizz, :litestream_aws_region),
         s3_endpoint: Application.get_env(:fizz, :litestream_s3_endpoint),
         s3_skip_verify: Application.get_env(:fizz, :litestream_s3_skip_verify, false),
         log_level: Application.get_env(:fizz, :litestream_log_level, "warn")},
        {Registry, keys: :unique, name: Fizz.Workflows.Runner.Registry},
        {Task.Supervisor, name: Fizz.Workflows.Runner.TaskSupervisor},
        {Fizz.Workflows.Runner.RunnableDispatcher,
         name: Fizz.Workflows.Runner.RunnableDispatcher},
        {Fizz.Workflows.Runner.RunnableConsumerSupervisor,
         dispatcher: Fizz.Workflows.Runner.RunnableDispatcher,
         task_supervisor: Fizz.Workflows.Runner.TaskSupervisor,
         max_concurrency: workflow_runnable_max_concurrency()},
        {Fizz.Workflows.Runner.WorkerSupervisor, name: Fizz.Workflows.Runner.WorkerSupervisor}
      ])
      |> maybe_add_child(
        Fizz.Workflows.TimerPoller,
        Application.get_env(:fizz, Fizz.Workflows.TimerPoller, [])
        |> Keyword.get(:enabled?, true)
      )
      |> maybe_add_child(
        Fizz.Workflows.SignalRouter,
        Application.get_env(:fizz, Fizz.Workflows.SignalRouter, [])
        |> Keyword.get(:enabled?, true)
      )
      |> Kernel.++([
        {Fizz.Workflows.PassivationSweeper,
         Application.get_env(:fizz, Fizz.Workflows.PassivationSweeper, [])},
        {DNSCluster, query: Application.get_env(:fizz, :dns_cluster_query) || :ignore},
        {Oban, Application.fetch_env!(:fizz, Oban)},
        {Phoenix.PubSub, name: Fizz.PubSub},
        FizzWeb.Presence,
        Fizz.Integrations.Registry,
        Fizz.Integrations.Catalog,

        # Step type registry - must start before endpoint so types are available
        Fizz.Steps.Registry
      ])
      |> maybe_add_child(
        Fizz.Triggers.Supervisor,
        Application.get_env(:fizz, Fizz.Triggers.Supervisor, [])
        |> Keyword.get(:enabled?, true)
      )
      |> Kernel.++([
        {DynamicSupervisor, name: Fizz.Workflows.DraftSessionSupervisor, strategy: :one_for_one},
        {Registry, keys: :unique, name: Fizz.Workflows.DraftSessionRegistry},
        # Start a worker by calling: Fizz.Worker.start_link(arg)
        # {Fizz.Worker, arg},
        # Start to serve requests, typically the last entry
        FizzWeb.Endpoint
      ])

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Fizz.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FizzWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp maybe_add_child(children, _child, false), do: children
  defp maybe_add_child(children, child, true), do: children ++ [child]

  defp workflow_runnable_max_concurrency do
    Application.get_env(:fizz, Fizz.Workflows, [])
    |> Keyword.get(:max_task_children, System.schedulers_online() * 4)
  end
end
