defmodule Fizz.Executions.Execution do
  @moduledoc """
  Workflow execution instance.

  Tracks the runtime state of a single workflow execution including
  status, timing, context (accumulated step outputs), and error information.
  """
  @derive {Jason.Encoder,
           only: [
             :id,
             :workflow_id,
             :status,
             :execution_type,
             :trigger,
             :context,
             :output,
             :error,
             :waiting_for,
             :started_at,
             :completed_at,
             :expires_at,
             :metadata,
             :triggered_by_user_id,
             :inserted_at,
             :updated_at
           ]}
  @derive {LiveVue.Encoder,
           only: [
             :id,
             :workflow_id,
             :status,
             :execution_type,
             :trigger,
             :context,
             :output,
             :error,
             :metadata,
             :triggered_by_user_id,
             :started_at,
             :completed_at,
             :inserted_at,
             :updated_at
           ]}
  use Fizz.Schema

  alias Fizz.Workflows.Workflow
  alias Fizz.Accounts.User
  alias Fizz.Executions.StepExecution

  @type status :: :pending | :running | :paused | :completed | :failed | :cancelled | :timeout
  @type trigger_type :: :manual | :schedule | :webhook | :event
  @type execution_type :: :production | :preview | :partial

  @statuses [:pending, :running, :paused, :completed, :failed, :cancelled, :timeout]
  @execution_types [:production, :preview, :partial]

  defmodule Trigger do
    @moduledoc "Embedded trigger data for an execution"
    @derive Jason.Encoder
    @derive {LiveVue.Encoder, only: [:type, :data]}
    use Ecto.Schema

    @type t :: %__MODULE__{
            type: Fizz.Executions.Execution.trigger_type(),
            data: map()
          }

    @primary_key false
    embedded_schema do
      field :type, Ecto.Enum, values: [:manual, :schedule, :webhook, :event]
      field :data, :map, default: %{}
    end
  end

  defmodule Metadata do
    @moduledoc "Embedded metadata for execution correlation and debugging"
    use Ecto.Schema
    @derive Jason.Encoder
    @derive {LiveVue.Encoder,
             only: [
               :trace_id,
               :correlation_id,
               :triggered_by,
               :parent_execution_id,
               :tags,
               :extras
             ]}

    @type t :: %__MODULE__{
            trace_id: String.t() | nil,
            correlation_id: String.t() | nil,
            triggered_by: String.t() | nil,
            parent_execution_id: Ecto.UUID.t() | nil,
            tags: map(),
            extras: map()
          }

    @primary_key false
    embedded_schema do
      field :trace_id, :string
      field :correlation_id, :string
      field :triggered_by, :string
      field :parent_execution_id, :binary_id
      field :tags, :map, default: %{}
      field :extras, :map, default: %{}
    end
  end

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          workflow_id: Ecto.UUID.t(),
          status: status(),
          execution_type: execution_type(),
          trigger: Trigger.t(),
          context: map(),
          output: map() | nil,
          error: map() | nil,
          waiting_for: map() | nil,
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          expires_at: DateTime.t() | nil,
          metadata: Metadata.t() | nil,
          triggered_by_user_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "executions" do
    belongs_to :workflow, Workflow

    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :execution_type, Ecto.Enum, values: @execution_types, default: :production

    embeds_one :trigger, Trigger, on_replace: :update
    embeds_one :metadata, Metadata, on_replace: :update

    # Accumulated outputs from all steps: %{"step_id" => output_data}
    field :context, :map, default: %{}

    # Final declared output (from an output step)
    field :output, :map

    # Error details if failed
    field :error, :map

    # For waiting/paused executions (e.g., awaiting webhook callback)
    field :waiting_for, :map

    # Timing
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :expires_at, :utc_datetime_usec

    belongs_to :triggered_by_user, User, foreign_key: :triggered_by_user_id
    has_many :step_executions, StepExecution

    timestamps()
  end

  def changeset(execution, attrs) do
    execution
    |> cast(attrs, [
      :workflow_id,
      :status,
      :execution_type,
      :context,
      :output,
      :error,
      :waiting_for,
      :started_at,
      :completed_at,
      :expires_at,
      :triggered_by_user_id
    ])
    |> cast_embed(:trigger, required: true, with: &trigger_changeset/2)
    |> cast_embed(:metadata, with: &metadata_changeset/2)
    |> validate_required([:workflow_id, :status, :execution_type])
    |> foreign_key_constraint(:workflow_id)
    |> foreign_key_constraint(:triggered_by_user_id)
  end

  defp trigger_changeset(trigger, attrs) do
    trigger
    |> cast(attrs, [:type, :data])
    |> validate_required([:type])
  end

  defp metadata_changeset(metadata, attrs) do
    metadata
    |> cast(attrs, [
      :trace_id,
      :correlation_id,
      :triggered_by,
      :parent_execution_id,
      :tags,
      :extras
    ])
  end

  # Convenience functions

  @doc "Returns the trigger type as an atom."
  def trigger_type(%__MODULE__{trigger: %Trigger{type: type}}), do: type
  def trigger_type(%__MODULE__{trigger: nil}), do: nil

  @doc "Returns the trigger input data."
  def trigger_data(%__MODULE__{trigger: %Trigger{data: data}}), do: data
  def trigger_data(%__MODULE__{trigger: nil}), do: %{}

  @doc "Checks if the execution is in a terminal state."
  def terminal?(%__MODULE__{status: status})
      when status in [:completed, :failed, :cancelled, :timeout],
      do: true

  def terminal?(%__MODULE__{}), do: false

  @doc "Checks if the execution is still running."
  def active?(%__MODULE__{status: status}) when status in [:pending, :running, :paused], do: true
  def active?(%__MODULE__{}), do: false

  @doc """
  Formats an execution error reason into a standard error map.
  """
  def format_error(reason) do
    case reason do
      %{"type" => _} = error ->
        error

      {:step_failed, step_id, step_reason} ->
        %{"type" => "step_failure", "step_id" => step_id, "reason" => inspect(step_reason)}

      {:workflow_build_failed, build_reason} ->
        %{"type" => "workflow_build_failed", "reason" => inspect(build_reason)}

      {:build_failed, message} ->
        %{"type" => "build_failure", "message" => message}

      {:cycle_detected, step_ids} ->
        %{"type" => "cycle_detected", "step_ids" => step_ids}

      {:invalid_connections, connections} ->
        %{
          "type" => "invalid_connections",
          "connections" =>
            Enum.map(connections, fn
              c when is_struct(c) -> Map.from_struct(c)
              c -> c
            end)
        }

      {:update_failed, %Ecto.Changeset{} = changeset} ->
        %{"type" => "update_failed", "errors" => inspect(changeset.errors)}

      {:unexpected_error, message} ->
        %{"type" => "unexpected_error", "message" => message}

      {:caught_error, kind, caught_reason} ->
        %{"type" => "caught_error", "kind" => inspect(kind), "reason" => inspect(caught_reason)}

      other ->
        %{"type" => "unknown", "reason" => inspect(other)}
    end
  end

  @doc "Computes duration in milliseconds, or nil if not yet complete."
  def duration_ms(%__MODULE__{started_at: nil}), do: nil
  def duration_ms(%__MODULE__{completed_at: nil}), do: nil

  def duration_ms(%__MODULE__{started_at: started, completed_at: completed}) do
    DateTime.diff(completed, started, :millisecond)
  end

  @doc "Computes duration in microseconds, or nil if not yet complete."
  def duration_us(%__MODULE__{started_at: nil}), do: nil
  def duration_us(%__MODULE__{completed_at: nil}), do: nil

  def duration_us(%__MODULE__{started_at: started, completed_at: completed}) do
    DateTime.diff(completed, started, :microsecond)
  end
end
