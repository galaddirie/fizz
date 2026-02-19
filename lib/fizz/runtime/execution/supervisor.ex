defmodule Fizz.Runtime.Execution.Supervisor do
  @moduledoc """
  DynamicSupervisor for workflow execution processes.
  """
  use DynamicSupervisor

  alias Fizz.Runtime.Execution.Server

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a new execution process.
  """
  def start_execution(execution_id, opts \\ []) do
    DynamicSupervisor.start_child(__MODULE__, {Server, [execution_id: execution_id] ++ opts})
  end

  @doc """
  Finds the pid of a running execution.
  """
  def get_execution_pid(execution_id) do
    case Registry.lookup(Fizz.Runtime.Execution.Registry, execution_id) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end
end
