defmodule Fizz.Executions.StepExecution do
  @moduledoc """
  Tracks individual step execution within a workflow execution.

  Each time a step runs (including retries), a new StepExecution record
  is created to capture input, output, timing, and any errors.
  """
  @derive {Jason.Encoder, except: [:__meta__, :execution]}
  @derive {LiveVue.Encoder,
           only: [
             :id,
             :execution_id,
             :step_id,
             :step_type_id,
             :status,
             :input_data,
             :output_data,
             :output_item_count,
             :item_index,
             :items_total,
             :error,
             :attempt,
             :retry_of_id,
             :queued_at,
             :started_at,
             :completed_at,
             :duration_us,
             :metadata,
             :inserted_at,
             :updated_at
           ]}
  use Fizz.Schema

  alias Ecto.Changeset
  alias Fizz.Executions.Execution

  @type status :: :pending | :queued | :running | :completed | :failed | :skipped | :cancelled

  @statuses [:pending, :queued, :running, :completed, :failed, :skipped, :cancelled]

  @allowed_transitions %{
    pending: [:queued, :running, :completed, :failed, :skipped, :cancelled],
    queued: [:running, :completed, :failed, :skipped, :cancelled],
    running: [:completed, :failed, :skipped, :cancelled],
    completed: [],
    failed: [],
    skipped: [],
    cancelled: []
  }

  @type t :: %__MODULE__{
          id: Ecto.UUID.t(),
          execution_id: Ecto.UUID.t(),
          step_id: String.t(),
          step_type_id: String.t(),
          status: status(),
          input_data: map() | nil,
          output_data: map() | nil,
          output_item_count: non_neg_integer() | nil,
          item_index: non_neg_integer() | nil,
          items_total: non_neg_integer() | nil,
          error: map() | nil,
          metadata: map(),
          queued_at: DateTime.t() | nil,
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          duration_us: integer() | nil,
          attempt: pos_integer(),
          retry_of_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "step_executions" do
    belongs_to :execution, Execution

    # Which step in the workflow definition
    field :step_id, :string
    field :step_type_id, :string

    field :status, Ecto.Enum, values: @statuses, default: :pending

    # Data flowing through this step
    field :input_data, :map
    field :output_data, :map
    field :output_item_count, :integer
    field :error, :map

    # Fan-out item tracking
    # NULL = single-item step (backwards compatible)
    # 0, 1, 2, ... = individual item within a fan-out batch
    field :item_index, :integer
    # Total items in batch (set on all records in a fan-out)
    field :items_total, :integer

    # Extensible metadata (retry backoff info, queue details, etc.)
    field :metadata, :map, default: %{}

    # Timing - when it was queued, started executing, and finished
    field :queued_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :completed_at, :utc_datetime_usec
    field :duration_us, :integer, virtual: true

    # Retry tracking
    field :attempt, :integer, default: 1
    field :retry_of_id, :binary_id

    timestamps()
  end

  def changeset(step_execution, attrs) do
    step_execution
    |> cast(attrs, [
      :execution_id,
      :step_id,
      :step_type_id,
      :status,
      :input_data,
      :output_data,
      :output_item_count,
      :item_index,
      :items_total,
      :error,
      :metadata,
      :queued_at,
      :started_at,
      :completed_at,
      :attempt,
      :retry_of_id
    ])
    |> validate_required([:execution_id, :step_id, :step_type_id, :status])
    |> validate_number(:attempt, greater_than: 0)
    |> validate_number(:item_index, greater_than_or_equal_to: 0)
    |> validate_number(:items_total, greater_than_or_equal_to: 1)
    |> validate_number(:output_item_count, greater_than_or_equal_to: 0)
    |> foreign_key_constraint(:execution_id)
    |> validate_status_transition()
  end

  # Convenience functions

  @doc "Checks if the step execution is in a terminal state."
  def terminal?(%__MODULE__{status: status})
      when status in [:completed, :failed, :skipped, :cancelled],
      do: true

  def terminal?(%__MODULE__{}), do: false

  @doc "Checks if the step execution succeeded."
  def succeeded?(%__MODULE__{status: :completed}), do: true
  def succeeded?(%__MODULE__{}), do: false

  @doc "Computes execution duration in milliseconds."
  def duration_ms(%__MODULE__{started_at: nil}), do: nil
  def duration_ms(%__MODULE__{completed_at: nil}), do: nil

  def duration_ms(%__MODULE__{started_at: started, completed_at: completed}) do
    DateTime.diff(completed, started, :millisecond)
  end

  @doc "Computes execution duration in microseconds."
  def duration_us(%__MODULE__{started_at: nil}), do: nil
  def duration_us(%__MODULE__{completed_at: nil}), do: nil

  def duration_us(%__MODULE__{started_at: started, completed_at: completed}) do
    DateTime.diff(completed, started, :microsecond)
  end

  @doc "Computes queue wait time in milliseconds."
  def queue_time_ms(%__MODULE__{queued_at: nil}), do: nil
  def queue_time_ms(%__MODULE__{started_at: nil}), do: nil

  def queue_time_ms(%__MODULE__{queued_at: queued, started_at: started}) do
    DateTime.diff(started, queued, :millisecond)
  end

  @doc "Computes queue wait time in microseconds."
  def queue_time_us(%__MODULE__{queued_at: nil}), do: nil
  def queue_time_us(%__MODULE__{started_at: nil}), do: nil

  def queue_time_us(%__MODULE__{queued_at: queued, started_at: started}) do
    DateTime.diff(started, queued, :microsecond)
  end

  @doc "Returns true if this is a retry attempt."
  def retry?(%__MODULE__{attempt: attempt}) when attempt > 1, do: true
  def retry?(%__MODULE__{}), do: false

  @doc "Returns true if this step execution is part of a fan-out batch."
  def fan_out_item?(%__MODULE__{item_index: nil}), do: false
  def fan_out_item?(%__MODULE__{item_index: _}), do: true

  @doc "Returns true if this is a multi-item step (items_total > 1)."
  def multi_item?(%__MODULE__{items_total: nil}), do: false
  def multi_item?(%__MODULE__{items_total: n}) when n > 1, do: true
  def multi_item?(%__MODULE__{}), do: false

  defp validate_status_transition(%Changeset{} = changeset) do
    case Changeset.fetch_change(changeset, :status) do
      {:ok, new_status} ->
        old_status = changeset.data.status

        if transition_allowed?(old_status, new_status) do
          changeset
        else
          Changeset.add_error(changeset, :status, "invalid status transition",
            validation: :transition
          )
        end

      :error ->
        changeset
    end
  end

  defp transition_allowed?(nil, _new_status), do: true
  defp transition_allowed?(old_status, new_status) when old_status == new_status, do: true

  defp transition_allowed?(old_status, new_status) do
    new_status in Map.get(@allowed_transitions, old_status, [])
  end
end
