defmodule Fizz.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {NodeJS.Supervisor, [path: LiveVue.SSR.NodeJS.server_path(), pool_size: 4]},
      FizzWeb.Telemetry,
      Fizz.Repo,
      {DNSCluster, query: Application.get_env(:fizz, :dns_cluster_query) || :ignore},
      {Oban, Application.fetch_env!(:fizz, Oban)},
      {Phoenix.PubSub, name: Fizz.PubSub},
      FizzWeb.Presence,

      # Step type registry - must start before endpoint so types are available
      Fizz.Steps.Registry,
      {Registry, keys: :unique, name: Fizz.Runtime.Execution.Registry},
      {Task.Supervisor, name: Fizz.Runtime.Execution.TaskSupervisor},
      Fizz.Runtime.Execution.Supervisor,
      Fizz.Runtime.Expression.Cache,
      # Trigger runtime
      Fizz.Runtime.Triggers.Registry,
      # Collaboration modules
      {Registry, keys: :unique, name: Fizz.Collaboration.EditSession.Registry},
      Fizz.Collaboration.EditSession.Supervisor,
      {Fizz.Collaboration.EditSession.Presence, []},

      # Start a worker by calling: Fizz.Worker.start_link(arg)
      # {Fizz.Worker, arg},
      # Start to serve requests, typically the last entry
      FizzWeb.Endpoint
    ]

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
end
