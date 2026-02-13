defmodule Fizz.Sprites.Broker.Supervisor do
  @moduledoc """
  Supervises runtime workspace broker processes.
  """

  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      {Registry, keys: :unique, name: Fizz.Sprites.Broker.Registry},
      {DynamicSupervisor, strategy: :one_for_one, name: Fizz.Sprites.Broker.WorkspaceSupervisor}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end
end
