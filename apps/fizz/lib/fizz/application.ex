defmodule Fizz.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      Fizz.Repo,
      {DNSCluster, query: Application.get_env(:fizz, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Fizz.PubSub}
      # Start a worker by calling: Fizz.Worker.start_link(arg)
      # {Fizz.Worker, arg}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Fizz.Supervisor)
  end
end
