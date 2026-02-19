defmodule Fizz.Runtime.Triggers.Registry do
  @moduledoc """
  GenServer that manages active triggers for published workflows.

  Responsibilities:
  - Tracks which workflows are active and have triggers.
  - Acts as a lookup for webhook routing (to verify workflow status).
  """
  use GenServer
  require Logger

  alias Fizz.Workflows
  alias Fizz.Workflows.Workflow
  alias Fizz.Repo

  @type state :: %{
          active_workflows: MapSet.t(),
          webhook_routes: %{String.t() => %{workflow_id: Ecto.UUID.t(), config: map()}}
        }

  # ============================================================================
  # API
  # ============================================================================

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Registers a workflow for trigger activation.
  Usually called when a workflow is published or toggled to 'active'.
  """
  def register(workflow_id, opts \\ [], name \\ __MODULE__) do
    GenServer.cast(name, {:register, workflow_id, opts})
  end

  @doc """
  Unregisters a workflow, stopping its child processes and removing it from active registry.
  """
  def unregister(workflow_id, name \\ __MODULE__) do
    GenServer.cast(name, {:unregister, workflow_id})
  end

  @doc """
  Checks if a workflow is currently active in the registry.
  """
  def active?(workflow_id, name \\ __MODULE__) do
    GenServer.call(name, {:is_active, workflow_id})
  end

  @doc """
  Looks up a webhook route in the registry.
  Returns {:ok, %{workflow_id: id, config: config}} or :error.
  """
  def lookup_webhook(path, method, name \\ __MODULE__) do
    GenServer.call(name, {:lookup_webhook, path, method})
  end

  # ============================================================================
  # Callbacks
  # ============================================================================

  @impl true
  def init(_opts) do
    Logger.info("Initializing Trigger Registry")

    {:ok, %{active_workflows: MapSet.new(), webhook_routes: %{}},
     {:continue, :load_active_workflows}}
  end

  @impl true
  def handle_continue(:load_active_workflows, state) do
    # Load all active workflows from DB and register them
    active_ids = load_active_workflow_ids()

    Logger.info("Trigger Registry: Loaded #{MapSet.size(active_ids)} active workflows")

    # Activate all loaded workflows
    active_ids
    |> Enum.each(fn id ->
      case Repo.get(Workflow, id) do
        nil -> :ok
        workflow -> Fizz.Runtime.Triggers.Activator.activate(workflow)
      end
    end)

    {:noreply, %{state | active_workflows: active_ids}}
  end

  defp load_active_workflow_ids do
    Workflows.list_active_workflows_query()
    |> Repo.all()
    |> Enum.map(& &1.id)
    |> MapSet.new()
  rescue
    error in Postgrex.Error ->
      if missing_workflows_table?(error) do
        Logger.warning("Trigger Registry: workflows table missing, skipping trigger bootstrap")
        MapSet.new()
      else
        reraise(error, __STACKTRACE__)
      end
  end

  defp missing_workflows_table?(%Postgrex.Error{postgres: %{code: :undefined_table}}), do: true
  defp missing_workflows_table?(%Postgrex.Error{postgres: %{pg_code: "42P01"}}), do: true
  defp missing_workflows_table?(_error), do: false

  @impl true
  def handle_cast({:register, workflow_id, opts}, state) do
    Logger.info("Registering triggers for workflow: #{workflow_id}")

    # Update active workflows
    active_workflows = MapSet.put(state.active_workflows, workflow_id)

    # Update webhook routes if provided
    webhook_routes =
      case Keyword.get(opts, :webhooks) do
        nil ->
          state.webhook_routes

        webhooks ->
          # First remove any old routes for this workflow (to avoid stale routes if config changed)
          cleaned_routes =
            state.webhook_routes
            |> Enum.reject(fn {_key, val} -> val.workflow_id == workflow_id end)
            |> Enum.into(%{})

          # Add new routes
          Enum.reduce(webhooks, cleaned_routes, fn %{path: path, method: method, config: config},
                                                   acc ->
            key = "#{method}:#{path}"
            Map.put(acc, key, %{workflow_id: workflow_id, config: config})
          end)
      end

    {:noreply, %{state | active_workflows: active_workflows, webhook_routes: webhook_routes}}
  end

  @impl true
  def handle_cast({:unregister, workflow_id}, state) do
    Logger.info("Unregistering triggers for workflow: #{workflow_id}")

    active_workflows = MapSet.delete(state.active_workflows, workflow_id)

    webhook_routes =
      state.webhook_routes
      |> Enum.reject(fn {_key, val} -> val.workflow_id == workflow_id end)
      |> Enum.into(%{})

    {:noreply, %{state | active_workflows: active_workflows, webhook_routes: webhook_routes}}
  end

  @impl true
  def handle_call({:lookup_webhook, path, method}, _from, state) do
    method = String.upcase(method)
    key = "#{method}:#{path}"

    reply =
      case Map.fetch(state.webhook_routes, key) do
        {:ok, _} = ok -> ok
        :error -> Map.fetch(state.webhook_routes, "ANY:#{path}")
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:is_active, workflow_id}, _from, state) do
    {:reply, MapSet.member?(state.active_workflows, workflow_id), state}
  end
end
