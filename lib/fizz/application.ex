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
      {Registry, keys: :unique, name: Fizz.Sprites.Console.Registry},
      Fizz.Sprites.Console.Supervisor,
      {Phoenix.PubSub, name: Fizz.PubSub},
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
