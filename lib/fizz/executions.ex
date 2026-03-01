defmodule Fizz.Executions do
  @moduledoc """
  Context for managing workflow executions and step executions.

  Provides functions to create, read, update, and manage executions,
  track execution status, and handle step-level execution details.
  """

  import Ecto.Query, warn: false
  require Logger
  alias Fizz.Repo

  alias Fizz.Executions.{Execution, Events, StepExecution}
  alias Fizz.Workflows.Workflow
  alias Fizz.Accounts.Scope
  alias Fizz.Runtime.Serializer

  @active_step_statuses [:pending, :queued, :running]
  @active_status_rank %{pending: 0, queued: 1, running: 2}
  @terminal_status_priority %{failed: 3, cancelled: 2, completed: 1, skipped: 0}
  @status_sort_rank %{
    pending: 0,
    queued: 1,
    running: 2,
    completed: 3,
    skipped: 4,
    cancelled: 5,
    failed: 6
  }
  @max_timestamp 9_999_999_999_999_999
  @internal_trigger_types [:schedule, :webhook, :event]

  @type execution_params :: %{
          required(:workflow_id) => Ecto.UUID.t(),
          required(:trigger) => map(),
          optional(:execution_type) => Execution.execution_type(),
          optional(:metadata) => map(),
          optional(:triggered_by_user_id) => Ecto.UUID.t()
        }

  @type step_execution_params :: %{
          required(:execution_id) => Ecto.UUID.t(),
          required(:step_id) => String.t(),
          required(:step_type_id) => String.t(),
          optional(:input_data) => map(),
          optional(:metadata) => map()
        }

  @doc """
  Lists executions accessible to the given scope.

  Returns executions for workflows in the active workspace.
  """
  @spec list_executions(Scope.t() | nil) :: [Execution.t()]
  def list_executions(%Scope{workspace: %{id: workspace_id}} = scope)
      when is_binary(workspace_id) do
    case Scope.can_view_workflow?(scope, %Workflow{workspace_id: workspace_id}) do
      true ->
        query =
          from e in Execution,
            join: w in Workflow,
            on: e.workflow_id == w.id,
            where: w.workspace_id == ^workspace_id,
            order_by: [desc: e.inserted_at],
            limit: 100

        Repo.all(query)

      false ->
        []
    end
  end

  def list_executions(_scope), do: []

  @doc """
  Lists executions for a specific workflow, checking access permissions.

  Returns executions if the user has access to the workflow, empty list otherwise.
  """
  @spec list_workflow_executions(Scope.t() | nil, Workflow.t(), keyword()) :: [Execution.t()]
  def list_workflow_executions(scope, %Workflow{} = workflow, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    if Scope.can_view_workflow?(scope, workflow) do
      Repo.all(
        from e in Execution,
          where: e.workflow_id == ^workflow.id,
          order_by: [desc: e.inserted_at],
          limit: ^limit,
          offset: ^offset
      )
    else
      []
    end
  end

  @doc """
  Gets a single execution by ID, checking access permissions.

  Returns `{:ok, execution}` if the user has access, `{:error, :not_found}` otherwise.
  """
  @spec get_execution(Scope.t() | nil, String.t() | Ecto.UUID.t()) ::
          {:ok, Execution.t()} | {:error, :not_found}
  def get_execution(scope, id) do
    case Repo.get(Execution, id) |> Repo.preload([:workflow, :triggered_by_user]) do
      nil ->
        {:error, :not_found}

      %Execution{} = execution ->
        if Scope.can_view_workflow?(scope, execution.workflow) do
          {:ok, execution}
        else
          {:error, :not_found}
        end
    end
  end

  @doc """
  Gets an execution with its step executions preloaded.

  Returns `{:ok, execution}` with step executions loaded, or `{:error, :not_found}`.
  """
  @spec get_execution_with_steps(Scope.t() | nil, String.t() | Ecto.UUID.t()) ::
          {:ok, Execution.t()} | {:error, :not_found}
  def get_execution_with_steps(scope, id) do
    case Repo.get(Execution, id)
         |> Repo.preload([
           :triggered_by_user,
           :step_executions,
           workflow: [:published_version, :draft]
         ]) do
      nil ->
        {:error, :not_found}

      %Execution{} = execution ->
        if Scope.can_view_workflow?(scope, execution.workflow) do
          {:ok, attach_step_execution_durations(execution)}
        else
          {:error, :not_found}
        end
    end
  end

  defp attach_step_execution_durations(%Execution{} = execution) do
    step_executions =
      Enum.map(execution.step_executions || [], fn step_execution ->
        %{step_execution | duration_us: StepExecution.duration_us(step_execution)}
      end)

    %{execution | step_executions: step_executions}
  end

  @doc """
  Creates a new execution for a workflow.

  Returns `{:ok, execution}` if successful, `{:error, changeset}` otherwise.
  """
  @spec create_execution(Scope.t() | nil, execution_params()) ::
          {:ok, Execution.t()}
          | {:error,
             Ecto.Changeset.t() | :workflow_not_found | :workflow_not_published | :access_denied}
  def create_execution(scope, attrs) do
    workflow_id = fetch_attr(attrs, :workflow_id)

    execution_type =
      attrs
      |> fetch_attr(:execution_type)
      |> normalize_execution_type()
      |> case do
        nil -> :production
        normalized_type -> normalized_type
      end

    case Repo.get(Workflow, workflow_id) do
      nil ->
        {:error, :workflow_not_found}

      workflow ->
        can_create = Scope.can_create_execution?(scope, workflow, execution_type)

        internal_scope_allowed? =
          internal_scope_execution_allowed?(scope, execution_type, fetch_attr(attrs, :trigger))

        cond do
          not can_create ->
            {:error, :access_denied}

          not internal_scope_allowed? ->
            {:error, :access_denied}

          true ->
            # Get the published version for production executions
            published_version_id = workflow.published_version_id

            cond do
              not is_nil(published_version_id) ->
                attrs =
                  attrs
                  |> maybe_put_triggered_by_user(scope)

                %Execution{}
                |> Execution.changeset(attrs)
                |> Repo.insert()

              execution_type in [:preview, :partial] ->
                attrs = maybe_put_triggered_by_user(attrs, scope)

                %Execution{}
                |> Execution.changeset(attrs)
                |> Repo.insert()

              true ->
                {:error, :workflow_not_published}
            end
        end
    end
  end

  defp maybe_put_triggered_by_user(attrs, scope) do
    if scope && scope.user do
      Map.put(attrs, :triggered_by_user_id, scope.user.id)
    else
      attrs
    end
  end

  defp fetch_attr(attrs, key) when is_map(attrs) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp fetch_attr(_attrs, _key), do: nil

  defp normalize_execution_type(type) when type in [:production, :preview, :partial], do: type
  defp normalize_execution_type("production"), do: :production
  defp normalize_execution_type("preview"), do: :preview
  defp normalize_execution_type("partial"), do: :partial
  defp normalize_execution_type(_type), do: nil

  defp internal_scope_execution_allowed?(nil, :production, trigger),
    do: internal_trigger?(trigger)

  defp internal_scope_execution_allowed?(nil, _execution_type, _trigger), do: false
  defp internal_scope_execution_allowed?(_scope, _execution_type, _trigger), do: true

  defp internal_trigger?(%{type: type}),
    do: normalize_trigger_type(type) in @internal_trigger_types

  defp internal_trigger?(%{"type" => type}),
    do: normalize_trigger_type(type) in @internal_trigger_types

  defp internal_trigger?(_), do: false

  defp can_manage_execution?(scope, %Workflow{} = workflow),
    do: Scope.can_edit_workflow?(scope, workflow)

  defp can_manage_execution?(_scope, _workflow), do: false

  defp normalize_trigger_type(type) when type in [:manual, :schedule, :webhook, :event], do: type
  defp normalize_trigger_type("manual"), do: :manual
  defp normalize_trigger_type("schedule"), do: :schedule
  defp normalize_trigger_type("webhook"), do: :webhook
  defp normalize_trigger_type("event"), do: :event
  defp normalize_trigger_type(_type), do: nil

  @doc """
  Updates an execution status.

  Returns `{:ok, execution}` if successful, `{:error, changeset | :access_denied}` otherwise.
  """
  @spec update_execution_status(Scope.t() | nil, Execution.t(), Execution.status(), keyword()) ::
          {:ok, Execution.t()} | {:error, Ecto.Changeset.t() | :access_denied}
  def update_execution_status(scope, %Execution{} = execution, status, opts \\ []) do
    # Ensure workflow is loaded
    execution = Repo.preload(execution, :workflow)

    if can_manage_execution?(scope, execution.workflow) do
      updates = %{status: status}

      # Add timestamps based on status
      updates =
        case status do
          :running ->
            Map.put(updates, :started_at, DateTime.utc_now())

          s when s in [:completed, :failed, :cancelled, :timeout] ->
            Map.put(updates, :completed_at, DateTime.utc_now())

          _ ->
            updates
        end

      # Add error information if provided
      updates =
        if Keyword.has_key?(opts, :error) do
          Map.put(updates, :error, Execution.format_error(Keyword.get(opts, :error)))
        else
          updates
        end

      # Add output if provided
      updates =
        if Keyword.has_key?(opts, :output) do
          Map.put(updates, :output, Keyword.get(opts, :output))
        else
          updates
        end

      # Add context if provided (allows preview executions to persist outputs)
      updates =
        if Keyword.has_key?(opts, :context) do
          Map.put(updates, :context, Keyword.get(opts, :context))
        else
          updates
        end

      execution
      |> Execution.changeset(updates)
      |> Repo.update()
    else
      {:error, :access_denied}
    end
  end

  @doc """
  Cancels an execution.

  Returns `{:ok, execution}` if successful, `{:error, reason}` otherwise.
  """
  @spec cancel_execution(Scope.t() | nil, Execution.t()) ::
          {:ok, Execution.t()} | {:error, :access_denied | :already_terminal}
  def cancel_execution(scope, %Execution{} = execution) do
    if Execution.terminal?(execution) do
      {:error, :already_terminal}
    else
      case update_execution_status(scope, execution, :cancelled) do
        {:ok, updated_execution} ->
          Events.emit(
            :execution_cancelled,
            updated_execution.id,
            %{status: :cancelled},
            workflow_id: updated_execution.workflow_id,
            source: :executions
          )

          # Cancel active steps
          cancel_active_step_executions(updated_execution.id)

          {:ok, updated_execution}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Cancels all active step executions for an execution.

  An active step is one with status :pending, :queued, or :running.
  All matched steps will be transitioned to :cancelled.
  """
  @spec cancel_active_step_executions(Ecto.UUID.t()) :: {integer(), nil | [term()]}
  def cancel_active_step_executions(execution_id) do
    now = DateTime.utc_now()

    query =
      from se in StepExecution,
        where: se.execution_id == ^execution_id and se.status in ^@active_step_statuses

    # We use update_all for efficiency, but we need to broadcast events.
    # In a high-scale system, we might just broadcast one "execution_cancelled" event
    # and let the UI handle it, but for granularity, we'll fetch and broadcast.
    active_steps = Repo.all(query)

    result =
      Repo.update_all(query,
        set: [
          status: :cancelled,
          completed_at: now,
          updated_at: now
        ]
      )

    Task.start(fn ->
      Enum.each(active_steps, fn step ->
        payload = %{
          id: step.id,
          execution_id: execution_id,
          step_id: step.step_id,
          status: :cancelled,
          completed_at: now,
          step_type_id: step.step_type_id,
          item_index: step.item_index,
          items_total: step.items_total,
          attempt: step.attempt,
          retry_of_id: step.retry_of_id,
          queued_at: step.queued_at,
          started_at: step.started_at,
          metadata: step.metadata
        }

        Fizz.Executions.PubSub.broadcast_step(:step_cancelled, execution_id, nil, payload)
      end)
    end)

    result
  end

  @doc """
  Lists step executions for an execution.

  Returns step executions ordered by insertion time.
  """
  @spec list_step_executions(Scope.t() | nil, Execution.t()) :: [StepExecution.t()]
  def list_step_executions(scope, %Execution{} = execution) do
    # Ensure workflow is loaded
    execution = Repo.preload(execution, :workflow)

    if Scope.can_view_workflow?(scope, execution.workflow) do
      Repo.all(
        from se in StepExecution,
          where: se.execution_id == ^execution.id,
          order_by: [asc: se.started_at, asc: se.inserted_at]
      )
    else
      []
    end
  end

  @doc """
  Gets a step execution by ID, checking access permissions.

  Returns `{:ok, step_execution}` if the user has access, `{:error, :not_found}` otherwise.
  """
  @spec get_step_execution(Scope.t() | nil, String.t() | Ecto.UUID.t()) ::
          {:ok, StepExecution.t()} | {:error, :not_found}
  def get_step_execution(scope, id) do
    case Repo.get(StepExecution, id) |> Repo.preload(execution: :workflow) do
      nil ->
        {:error, :not_found}

      %StepExecution{execution: execution} = step_execution ->
        if Scope.can_view_workflow?(scope, execution.workflow) do
          {:ok, step_execution}
        else
          {:error, :not_found}
        end
    end
  end

  @doc """
  Creates a step execution.

  Returns `{:ok, step_execution}` if successful, `{:error, changeset}` otherwise.
  """
  @spec create_step_execution(Scope.t() | nil, step_execution_params()) ::
          {:ok, StepExecution.t()}
          | {:error, Ecto.Changeset.t() | :execution_not_found | :access_denied}
  def create_step_execution(scope, attrs) do
    execution_id = fetch_attr(attrs, :execution_id)

    case Repo.get(Execution, execution_id) |> Repo.preload(:workflow) do
      nil ->
        {:error, :execution_not_found}

      execution ->
        if can_manage_execution?(scope, execution.workflow) do
          %StepExecution{}
          |> StepExecution.changeset(attrs)
          |> Repo.insert()
        else
          {:error, :access_denied}
        end
    end
  end

  @doc """
  Updates a step execution status.

  Returns `{:ok, step_execution}` if successful, `{:error, changeset | :access_denied}` otherwise.
  """
  @spec update_step_execution_status(
          Scope.t() | nil,
          StepExecution.t(),
          StepExecution.status(),
          keyword()
        ) ::
          {:ok, StepExecution.t()} | {:error, Ecto.Changeset.t() | :not_found | :access_denied}
  def update_step_execution_status(scope, %StepExecution{} = step_execution, status, opts \\ []) do
    case Repo.get(Execution, step_execution.execution_id) |> Repo.preload(:workflow) do
      nil ->
        {:error, :not_found}

      execution ->
        if can_manage_execution?(scope, execution.workflow) do
          updates = %{status: status}

          # Add timestamps based on status
          updates =
            case status do
              :running ->
                Map.put(updates, :started_at, DateTime.utc_now())

              :queued ->
                Map.put(updates, :queued_at, DateTime.utc_now())

              s when s in [:completed, :failed, :skipped] ->
                Map.put(updates, :completed_at, DateTime.utc_now())

              _ ->
                updates
            end

          # Add output data if provided
          updates =
            if Keyword.has_key?(opts, :output_data) do
              Map.put(updates, :output_data, Keyword.get(opts, :output_data))
            else
              updates
            end

          # Add error if provided
          updates =
            if Keyword.has_key?(opts, :error) do
              Map.put(updates, :error, Keyword.get(opts, :error))
            else
              updates
            end

          # Add output_item_count if provided
          updates =
            if Keyword.has_key?(opts, :output_item_count) do
              Map.put(updates, :output_item_count, Keyword.get(opts, :output_item_count))
            else
              updates
            end

          step_execution
          |> StepExecution.changeset(updates)
          |> Repo.update()
        else
          {:error, :access_denied}
        end
    end
  end

  @doc """
  Creates a retry step execution.

  Returns `{:ok, step_execution}` if successful, `{:error, changeset | :access_denied}` otherwise.
  """
  @spec retry_step_execution(Scope.t() | nil, StepExecution.t()) ::
          {:ok, StepExecution.t()} | {:error, Ecto.Changeset.t() | :not_found | :access_denied}
  def retry_step_execution(scope, %StepExecution{} = original) do
    case Repo.get(Execution, original.execution_id) |> Repo.preload(:workflow) do
      nil ->
        {:error, :not_found}

      execution ->
        if can_manage_execution?(scope, execution.workflow) do
          %StepExecution{}
          |> StepExecution.changeset(%{
            execution_id: original.execution_id,
            step_id: original.step_id,
            step_type_id: original.step_type_id,
            input_data: original.input_data,
            metadata: original.metadata,
            attempt: original.attempt + 1,
            retry_of_id: original.id
          })
          |> Repo.insert()
        else
          {:error, :access_denied}
        end
    end
  end

  @doc false
  @spec record_step_execution_started(Ecto.UUID.t(), String.t(), String.t(), term()) ::
          {:ok, StepExecution.t()} | {:error, Ecto.Changeset.t() | term()}
  def record_step_execution_started(execution_id, step_id, step_type_id, input_data) do
    attrs = %{
      execution_id: execution_id,
      step_id: step_id,
      step_type_id: step_type_id,
      status: :running,
      input_data: Serializer.wrap_for_db(input_data),
      started_at: DateTime.utc_now()
    }

    safe_repo(fn ->
      %StepExecution{}
      |> StepExecution.changeset(attrs)
      |> Repo.insert()
    end)
  end

  @doc false
  @spec record_step_execution_completed_by_id(Ecto.UUID.t(), term()) ::
          {:ok, StepExecution.t()} | {:error, Ecto.Changeset.t() | :not_found | term()}
  def record_step_execution_completed_by_id(step_execution_id, output_data, opts \\ []) do
    case Repo.get(StepExecution, step_execution_id) do
      nil ->
        {:error, :not_found}

      %StepExecution{} = step_execution ->
        updates = %{
          status: :completed,
          output_data: Serializer.wrap_for_db(output_data),
          output_item_count: Keyword.get(opts, :output_item_count),
          completed_at: DateTime.utc_now()
        }

        safe_repo(fn ->
          step_execution
          |> StepExecution.changeset(updates)
          |> Repo.update()
        end)
    end
  end

  @doc false
  @spec record_step_execution_completed_by_step(Ecto.UUID.t(), String.t(), term(), keyword()) ::
          {:ok, StepExecution.t()} | {:error, Ecto.Changeset.t() | :not_found | term()}
  def record_step_execution_completed_by_step(execution_id, step_id, output_data, opts \\ []) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    error = Keyword.get(opts, :error)
    output_item_count = Keyword.get(opts, :output_item_count)

    updates = [
      status: :completed,
      output_data: Serializer.wrap_for_db(output_data),
      output_item_count: output_item_count,
      completed_at: now,
      updated_at: now
    ]

    updates = if error, do: Keyword.put(updates, :error, error), else: updates

    query =
      from(se in StepExecution,
        where:
          se.execution_id == ^execution_id and se.step_id == ^step_id and
            se.status in ^@active_step_statuses
      )

    safe_repo(fn ->
      case Repo.update_all(query, [set: updates], returning: true) do
        {0, _} ->
          {:error, :not_found}

        {1, [step]} ->
          {:ok, step}

        {n, steps} ->
          Logger.warning("Updated multiple step executions (#{n}) for completion",
            execution_id: execution_id,
            step_id: step_id
          )

          {:ok, List.last(steps)}
      end
    end)
  end

  @doc false
  @spec record_step_execution_failed_by_step(Ecto.UUID.t(), String.t(), term()) ::
          {:ok, StepExecution.t()} | {:error, Ecto.Changeset.t() | :not_found | term()}
  def record_step_execution_failed_by_step(execution_id, step_id, reason) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    error = Execution.format_error({:step_failed, step_id, reason})

    entry = %{
      execution_id: execution_id,
      step_id: step_id,
      status: :failed,
      error: error,
      completed_at: now
    }

    safe_repo(fn ->
      case persist_step_execution_entries([entry], now) do
        {:ok, step_execution, _action} -> {:ok, step_execution}
        {:error, failure_reason} -> {:error, failure_reason}
      end
    end)
  end

  @doc false
  @spec record_step_execution_skipped_by_step(Ecto.UUID.t(), String.t()) ::
          {:ok, StepExecution.t()} | {:error, Ecto.Changeset.t() | :not_found | term()}
  def record_step_execution_skipped_by_step(execution_id, step_id) do
    case fetch_latest_active_step_execution(execution_id, step_id) do
      nil ->
        {:error, :not_found}

      %StepExecution{} = step_execution ->
        updates = %{
          status: :skipped,
          completed_at: DateTime.utc_now()
        }

        safe_repo(fn ->
          step_execution
          |> StepExecution.changeset(updates)
          |> Repo.update()
        end)
    end
  end

  @doc false
  @spec update_step_execution_metadata(Ecto.UUID.t(), String.t(), map()) ::
          {:ok, StepExecution.t()} | {:error, term()}

  def update_step_execution_metadata(execution_id, step_id, metadata) do
    case fetch_latest_active_step_execution(execution_id, step_id) do
      nil ->
        {:error, :not_found}

      %StepExecution{} = step_execution ->
        new_metadata = Map.merge(step_execution.metadata || %{}, metadata)

        safe_repo(fn ->
          step_execution
          |> StepExecution.changeset(%{metadata: new_metadata})
          |> Repo.update()
        end)
    end
  end

  @doc """
  Records multiple step executions in a single batch.
  Merges step events per step and persists them with FSM-aware, commutative semantics.
  """
  @spec record_step_executions_batch([map()]) :: {:ok, integer()} | {:error, term()}
  def record_step_executions_batch(batches) when is_list(batches) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    batches
    |> Enum.map(&normalize_step_entry/1)
    |> Enum.filter(&valid_step_entry?/1)
    |> case do
      [] ->
        {:ok, 0}

      entries ->
        safe_repo(fn ->
          entries
          |> Enum.group_by(fn entry ->
            # Include item_index in grouping key to keep fan-out items separate
            {entry.execution_id, entry.step_id, entry.item_index, entry.attempt || 1}
          end)
          |> Enum.reduce_while({:ok, 0}, fn {_key, grouped_entries}, {:ok, count} ->
            case persist_step_execution_entries(grouped_entries, now) do
              {:ok, _step_execution, :noop} ->
                {:cont, {:ok, count}}

              {:ok, _step_execution, _action} ->
                {:cont, {:ok, count + 1}}

              {:error, reason} ->
                {:halt, {:error, reason}}
            end
          end)
        end)
    end
  end

  defp persist_step_execution_entries(entries, now) when is_list(entries) do
    [first | _] = entries
    execution_id = Map.get(first, :execution_id)
    step_id = Map.get(first, :step_id)
    item_index = Map.get(first, :item_index)
    attempt = Map.get(first, :attempt) || 1

    existing = fetch_latest_step_execution(execution_id, step_id, item_index, attempt)
    merged = merge_step_entries([existing | entries], now)

    if valid_step_entry?(merged) do
      attrs = step_execution_attrs(merged)

      case existing do
        nil ->
          case StepExecution.changeset(%StepExecution{}, attrs) |> Repo.insert() do
            {:ok, step_execution} -> {:ok, step_execution, :inserted}
            {:error, changeset} -> {:error, changeset}
          end

        %StepExecution{} = step_execution ->
          changeset = StepExecution.changeset(step_execution, attrs)

          cond do
            changeset.changes == %{} ->
              {:ok, step_execution, :noop}

            changeset.valid? ->
              case Repo.update(changeset) do
                {:ok, updated} -> {:ok, updated, :updated}
                {:error, update_error} -> {:error, update_error}
              end

            transition_error?(changeset) ->
              {:ok, step_execution, :noop}

            true ->
              {:error, changeset}
          end
      end
    else
      {:error, :invalid_entry}
    end
  end

  defp merge_step_entries(entries, now) do
    normalized =
      entries
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&normalize_step_entry/1)
      |> Enum.filter(&valid_step_entry?/1)

    case normalized do
      [] ->
        %{}

      _ ->
        base = List.first(normalized)
        status = choose_step_status(normalized)
        queued_at = min_datetime(normalized, :queued_at)
        started_at = min_datetime(normalized, :started_at)

        completed_at =
          normalized
          |> max_datetime(:completed_at)
          |> maybe_default_completed_at(status, now)

        %{
          execution_id: base.execution_id,
          step_id: base.step_id,
          step_type_id: pick_first_non_nil(normalized, :step_type_id),
          status: status,
          input_data: pick_input_data(normalized),
          output_data: pick_output_data(normalized),
          output_item_count: pick_output_item_count(normalized),
          item_index: pick_first_non_nil(normalized, :item_index),
          items_total: pick_first_non_nil(normalized, :items_total),
          error: pick_error(normalized),
          metadata: merge_metadata(normalized),
          queued_at: queued_at,
          started_at: started_at,
          completed_at: completed_at,
          attempt: pick_attempt(normalized),
          retry_of_id: pick_first_non_nil(normalized, :retry_of_id)
        }
    end
  end

  defp step_execution_attrs(merged) do
    %{
      execution_id: merged.execution_id,
      step_id: merged.step_id,
      step_type_id: merged.step_type_id || "unknown",
      status: merged.status || :pending,
      input_data: Serializer.wrap_for_db(merged.input_data),
      output_data: Serializer.wrap_for_db(merged.output_data),
      output_item_count: merged.output_item_count,
      item_index: merged[:item_index],
      items_total: merged[:items_total],
      error: merged.error,
      metadata: merged.metadata || %{},
      queued_at: merged.queued_at,
      started_at: merged.started_at,
      completed_at: merged.completed_at,
      attempt: merged.attempt || 1,
      retry_of_id: merged.retry_of_id
    }
  end

  defp normalize_step_entry(%StepExecution{} = step_execution) do
    %{
      execution_id: step_execution.execution_id,
      step_id: step_execution.step_id,
      step_type_id: step_execution.step_type_id,
      status: step_execution.status,
      input_data: step_execution.input_data,
      output_data: step_execution.output_data,
      output_item_count: step_execution.output_item_count,
      item_index: step_execution.item_index,
      items_total: step_execution.items_total,
      error: step_execution.error,
      metadata: step_execution.metadata,
      queued_at: step_execution.queued_at,
      started_at: step_execution.started_at,
      completed_at: step_execution.completed_at,
      attempt: step_execution.attempt,
      retry_of_id: step_execution.retry_of_id
    }
  end

  defp normalize_step_entry(entry) when is_map(entry) do
    %{
      execution_id: fetch_step_value(entry, :execution_id),
      step_id: fetch_step_value(entry, :step_id),
      step_type_id: fetch_step_value(entry, :step_type_id),
      status: normalize_status(fetch_step_value(entry, :status)),
      input_data: fetch_step_value(entry, :input_data),
      output_data: fetch_step_value(entry, :output_data),
      output_item_count: fetch_step_value(entry, :output_item_count),
      item_index: fetch_step_value(entry, :item_index),
      items_total: fetch_step_value(entry, :items_total),
      error: fetch_step_value(entry, :error),
      metadata: normalize_metadata(fetch_step_value(entry, :metadata)),
      queued_at: normalize_datetime(fetch_step_value(entry, :queued_at)),
      started_at: normalize_datetime(fetch_step_value(entry, :started_at)),
      completed_at: normalize_datetime(fetch_step_value(entry, :completed_at)),
      attempt: fetch_step_value(entry, :attempt),
      retry_of_id: fetch_step_value(entry, :retry_of_id)
    }
  end

  defp normalize_step_entry(_entry), do: %{}

  defp valid_step_entry?(entry) do
    execution_id = Map.get(entry, :execution_id)
    step_id = Map.get(entry, :step_id)
    is_binary(execution_id) and is_binary(step_id) and step_id != ""
  end

  defp fetch_step_value(entry, key) do
    Map.get(entry, key) || Map.get(entry, Atom.to_string(key))
  end

  defp normalize_status(status) when is_atom(status), do: status

  defp normalize_status(status) when is_binary(status) do
    case status do
      "pending" -> :pending
      "queued" -> :queued
      "running" -> :running
      "completed" -> :completed
      "failed" -> :failed
      "skipped" -> :skipped
      "cancelled" -> :cancelled
      _ -> nil
    end
  end

  defp normalize_status(_), do: nil

  defp normalize_metadata(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata(_), do: %{}

  defp normalize_datetime(%DateTime{} = dt), do: dt
  defp normalize_datetime(_), do: nil

  defp choose_step_status(entries) do
    {terminal_entries, active_entries} =
      Enum.split_with(entries, fn entry -> terminal_status?(entry.status) end)

    cond do
      terminal_entries != [] ->
        terminal_entries
        |> Enum.max_by(&terminal_status_key/1)
        |> Map.get(:status)

      active_entries != [] ->
        active_entries
        |> Enum.max_by(&active_status_key/1)
        |> Map.get(:status)

      true ->
        :pending
    end
  end

  defp terminal_status?(status) when status in [:completed, :failed, :skipped, :cancelled],
    do: true

  defp terminal_status?(_status), do: false

  defp terminal_status_key(entry) do
    {
      timestamp_to_int(entry.completed_at),
      Map.get(@terminal_status_priority, entry.status, 0)
    }
  end

  defp active_status_key(entry) do
    {
      Map.get(@active_status_rank, entry.status, 0),
      timestamp_to_int(active_status_time(entry))
    }
  end

  defp active_status_time(%{status: :running} = entry), do: entry.started_at
  defp active_status_time(%{status: :queued} = entry), do: entry.queued_at
  defp active_status_time(_entry), do: nil

  defp pick_first_non_nil(entries, key) do
    entries
    |> sort_entries_by_event_time(:asc)
    |> Enum.find_value(&Map.get(&1, key))
  end

  defp pick_attempt(entries) do
    entries
    |> Enum.map(&Map.get(&1, :attempt))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> 1 end)
  end

  defp pick_input_data(entries) do
    entries
    |> sort_entries_by_timestamp(:started_at, :asc)
    |> Enum.find_value(&Map.get(&1, :input_data))
  end

  defp pick_output_data(entries) do
    entries
    |> Enum.filter(&terminal_status?(&1.status))
    |> sort_entries_by_timestamp(:completed_at, :desc)
    |> Enum.find_value(&Map.get(&1, :output_data))
  end

  defp pick_output_item_count(entries) do
    entries
    |> Enum.filter(&terminal_status?(&1.status))
    |> sort_entries_by_timestamp(:completed_at, :desc)
    |> Enum.find_value(&Map.get(&1, :output_item_count))
  end

  defp pick_error(entries) do
    entries
    |> Enum.filter(&Map.get(&1, :error))
    |> sort_entries_by_timestamp(:completed_at, :desc)
    |> Enum.find_value(&Map.get(&1, :error))
  end

  defp merge_metadata(entries) do
    entries
    |> sort_entries_by_event_time(:asc)
    |> Enum.reduce(%{}, fn entry, acc ->
      Map.merge(acc, entry.metadata || %{})
    end)
  end

  defp min_datetime(entries, key) do
    entries
    |> Enum.map(&Map.get(&1, key))
    |> Enum.reject(&is_nil/1)
    |> Enum.min(fn -> nil end)
  end

  defp max_datetime(entries, key) do
    entries
    |> Enum.map(&Map.get(&1, key))
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> nil end)
  end

  defp maybe_default_completed_at(nil, status, now)
       when status in [:completed, :failed, :skipped, :cancelled],
       do: now

  defp maybe_default_completed_at(completed_at, _status, _now), do: completed_at

  defp sort_entries_by_timestamp(entries, field, order) do
    Enum.sort_by(entries, fn entry ->
      timestamp_sort_key(Map.get(entry, field), order, entry.status)
    end)
  end

  defp sort_entries_by_event_time(entries, order) do
    Enum.sort_by(entries, fn entry ->
      timestamp_sort_key(event_time(entry), order, entry.status)
    end)
  end

  defp event_time(entry) do
    case entry.status do
      status when status in [:completed, :failed, :skipped, :cancelled] ->
        entry.completed_at

      :running ->
        entry.started_at

      :queued ->
        entry.queued_at

      _ ->
        nil
    end
  end

  defp timestamp_sort_key(%DateTime{} = dt, :asc, status) do
    {DateTime.to_unix(dt, :microsecond), Map.get(@status_sort_rank, status, 0)}
  end

  defp timestamp_sort_key(%DateTime{} = dt, :desc, status) do
    {-DateTime.to_unix(dt, :microsecond), Map.get(@status_sort_rank, status, 0)}
  end

  defp timestamp_sort_key(nil, :asc, status) do
    {@max_timestamp, Map.get(@status_sort_rank, status, 0)}
  end

  defp timestamp_sort_key(nil, :desc, status) do
    {0, Map.get(@status_sort_rank, status, 0)}
  end

  defp timestamp_to_int(%DateTime{} = dt), do: DateTime.to_unix(dt, :microsecond)
  defp timestamp_to_int(_), do: 0

  defp transition_error?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:status, {_message, opts}} -> Keyword.get(opts, :validation) == :transition
      _ -> false
    end)
  end

  defp fetch_latest_step_execution(nil, _step_id, _item_index, _attempt), do: nil

  defp fetch_latest_step_execution(execution_id, step_id, item_index, attempt) do
    case Ecto.UUID.cast(execution_id) do
      {:ok, uuid} ->
        query =
          from(se in StepExecution,
            where:
              se.execution_id == ^uuid and se.step_id == ^step_id and
                se.attempt == ^attempt,
            order_by: [desc: se.inserted_at],
            limit: 1
          )

        # Add item_index filter - use is_nil for NULL matching
        query =
          if is_nil(item_index) do
            from(se in query, where: is_nil(se.item_index))
          else
            from(se in query, where: se.item_index == ^item_index)
          end

        Repo.one(query)

      :error ->
        nil
    end
  end

  defp fetch_latest_active_step_execution(nil, _step_id), do: nil

  defp fetch_latest_active_step_execution(execution_id, step_id) do
    case Ecto.UUID.cast(execution_id) do
      {:ok, uuid} ->
        from(se in StepExecution,
          where:
            se.execution_id == ^uuid and se.step_id == ^step_id and
              se.status in ^@active_step_statuses,
          order_by: [desc: se.inserted_at],
          limit: 1
        )
        |> Repo.one()

      :error ->
        nil
    end
  end

  defp safe_repo(fun) when is_function(fun, 0) do
    fun.()
  rescue
    error ->
      {:error, error}
  end

  @doc """
  Counts executions by status for the given scope.

  Returns a map with status counts.
  """
  @spec count_executions_by_status(Scope.t() | nil) :: %{optional(atom()) => non_neg_integer()}
  def count_executions_by_status(%Scope{workspace: %{id: workspace_id}} = scope)
      when is_binary(workspace_id) do
    case Scope.can_view_workflow?(scope, %Workflow{workspace_id: workspace_id}) do
      true ->
        query =
          from e in Execution,
            join: w in Workflow,
            on: e.workflow_id == w.id,
            where: w.workspace_id == ^workspace_id,
            select: {e.status, count(e.id)},
            group_by: e.status

        Repo.all(query) |> Map.new()

      false ->
        %{}
    end
  end

  def count_executions_by_status(_scope), do: %{}

  @doc """
  Gets execution statistics for the last N days.

  Returns a list of daily execution counts.
  """
  @spec get_execution_stats(Scope.t() | nil, pos_integer()) :: [
          %{date: Date.t(), count: non_neg_integer()}
        ]
  def get_execution_stats(scope, days \\ 30)

  def get_execution_stats(%Scope{workspace: %{id: workspace_id}} = scope, days)
      when is_binary(workspace_id) do
    case Scope.can_view_workflow?(scope, %Workflow{workspace_id: workspace_id}) do
      true ->
        start_date = Date.add(Date.utc_today(), -days)

        query =
          from e in Execution,
            join: w in Workflow,
            on: e.workflow_id == w.id,
            where: w.workspace_id == ^workspace_id,
            where: fragment("date(?) >= ?", e.inserted_at, ^start_date),
            select: %{
              date: fragment("date(?)", e.inserted_at),
              count: count(e.id)
            },
            group_by: fragment("date(?)", e.inserted_at),
            order_by: fragment("date(?)", e.inserted_at)

        Repo.all(query)

      false ->
        []
    end
  end

  def get_execution_stats(_scope, _days), do: []
end
