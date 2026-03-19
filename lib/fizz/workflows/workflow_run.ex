defmodule Fizz.Workflows.WorkflowRun do
  @moduledoc """
  Durable record of a workflow execution.

  A workflow run stores the project-scoped execution state for a published
  workflow definition version, including its lifecycle status, input/output,
  durable bookkeeping fields, and lineage when a run is continued into another.

  Status transitions are intentionally constrained by `transition_status/2` so
  callers cannot move a run through an invalid lifecycle edge.
  """

  use Fizz.Schema

  alias Fizz.Accounts.Project
  alias Fizz.Workflows.{WorkflowDefinition, WorkflowDefinitionVersion}

  @statuses ~w(pending running sleeping passivated completed failed cancelled continued)a
  @terminal_statuses ~w(completed failed cancelled continued)a
  @transition_graph %{
    pending: MapSet.new([:running]),
    running: MapSet.new([:sleeping, :passivated, :completed, :failed, :cancelled, :continued]),
    sleeping: MapSet.new([:running, :passivated, :cancelled]),
    passivated: MapSet.new([:running]),
    completed: MapSet.new(),
    failed: MapSet.new(),
    cancelled: MapSet.new(),
    continued: MapSet.new()
  }

  schema "workflow_runs" do
    field :workos_organization_id, :string
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :input, :map, default: %{}
    field :output, :map
    field :error, :map
    field :storage_uri, :string
    field :last_active_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :compiled_hash, :string

    belongs_to :workflow_definition, WorkflowDefinition
    belongs_to :workflow_definition_version, WorkflowDefinitionVersion
    belongs_to :project, Project
    belongs_to :continued_from_run, __MODULE__, foreign_key: :continued_from_run_id

    timestamps()
  end

  @doc """
  Returns the supported workflow run statuses.
  """
  def statuses, do: @statuses

  @doc """
  Returns whether the given run or status is terminal.
  """
  def terminal?(%__MODULE__{status: status}), do: terminal?(status)
  def terminal?(status) when is_atom(status), do: status in @terminal_statuses

  def terminal?(status) when is_binary(status) do
    case normalize_status(status) do
      {:ok, normalized} -> terminal?(normalized)
      :error -> false
    end
  end

  def terminal?(_status), do: false

  @doc false
  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :workflow_definition_id,
      :workflow_definition_version_id,
      :project_id,
      :workos_organization_id,
      :status,
      :input,
      :output,
      :error,
      :storage_uri,
      :last_active_at,
      :started_at,
      :completed_at,
      :continued_from_run_id,
      :compiled_hash
    ])
    |> validate_required([
      :workflow_definition_id,
      :workflow_definition_version_id,
      :project_id,
      :workos_organization_id,
      :status,
      :input,
      :last_active_at
    ])
    |> validate_length(:workos_organization_id, min: 3, max: 255)
    |> foreign_key_constraint(:workflow_definition_id)
    |> foreign_key_constraint(:workflow_definition_version_id)
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:continued_from_run_id)
    |> check_constraint(:status, name: :workflow_runs_status_check)
  end

  @doc """
  Builds a changeset that transitions a run to a new lifecycle status.

  The transition is validated against the allowed status graph and stamps
  `started_at` or `completed_at` when the target status requires it.
  """
  def transition_status(%__MODULE__{} = run, new_status) do
    run
    |> changeset(%{status: new_status})
    |> validate_transition(run)
    |> maybe_put_started_at(run, new_status)
    |> maybe_put_completed_at(run, new_status)
  end

  @doc """
  Updates `last_active_at` to the current UTC time.
  """
  def touch_last_active(%__MODULE__{} = run) do
    change(run, last_active_at: DateTime.utc_now())
  end

  defp validate_transition(%Ecto.Changeset{valid?: false} = changeset, _run), do: changeset

  defp validate_transition(changeset, %__MODULE__{status: current_status}) do
    case get_change(changeset, :status) do
      nil ->
        add_error(changeset, :status, "must change")

      new_status ->
        if valid_transition?(current_status, new_status) do
          changeset
        else
          add_error(
            changeset,
            :status,
            "cannot transition from #{current_status} to #{new_status}"
          )
        end
    end
  end

  defp valid_transition?(current_status, new_status)
       when is_atom(current_status) and is_atom(new_status) do
    @transition_graph
    |> Map.get(current_status, MapSet.new())
    |> MapSet.member?(new_status)
  end

  defp valid_transition?(_current_status, _new_status), do: false

  defp maybe_put_started_at(changeset, %__MODULE__{started_at: nil}, new_status) do
    case normalize_status(new_status) do
      {:ok, :running} -> put_change(changeset, :started_at, DateTime.utc_now())
      _ -> changeset
    end
  end

  defp maybe_put_started_at(changeset, _run, _new_status), do: changeset

  defp maybe_put_completed_at(changeset, %__MODULE__{completed_at: nil}, new_status) do
    case normalize_status(new_status) do
      {:ok, normalized} when normalized in @terminal_statuses ->
        put_change(changeset, :completed_at, DateTime.utc_now())

      _ ->
        changeset
    end
  end

  defp maybe_put_completed_at(changeset, _run, _new_status), do: changeset

  defp normalize_status(status) when status in @statuses, do: {:ok, status}

  defp normalize_status(status) when is_binary(status) do
    status
    |> String.trim()
    |> case do
      "" -> :error
      value -> value |> String.to_existing_atom() |> normalize_status()
    end
  rescue
    ArgumentError -> :error
  end

  defp normalize_status(_status), do: :error
end
