defmodule Fizz.Collaboration.EditSession.Supervisor do
  @moduledoc """
  DynamicSupervisor for edit session processes.
  """
  use DynamicSupervisor

  alias Fizz.Collaboration.EditSession.Server

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc "Start or get an existing edit session for a workflow."
  def ensure_session(scope, workflow_id) do
    case Registry.lookup(Fizz.Collaboration.EditSession.Registry, workflow_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        start_session(scope, workflow_id)
    end
  end

  @doc "Start a new edit session."
  def start_session(scope, workflow_id) do
    spec = {Server, workflow_id: workflow_id, scope: scope}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @doc "Stop an edit session."
  def stop_session(workflow_id) do
    case Registry.lookup(Fizz.Collaboration.EditSession.Registry, workflow_id) do
      [{pid, _}] ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)

      [] ->
        {:error, :not_found}
    end
  end
end
