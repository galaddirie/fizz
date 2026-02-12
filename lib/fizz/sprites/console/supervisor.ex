defmodule Fizz.Sprites.Console.Supervisor do
  @moduledoc """
  Dynamic supervisor for sprite console sessions.
  """

  use DynamicSupervisor

  alias Fizz.Sprites.Console.SessionServer

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec start_session(keyword()) :: DynamicSupervisor.on_start_child()
  def start_session(opts) when is_list(opts) do
    child_spec = {SessionServer, opts}
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end
end
