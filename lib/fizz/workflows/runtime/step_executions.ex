defmodule Fizz.Workflows.Runtime.StepExecutions do
  @moduledoc false

  alias Fizz.Workflows.Embeds.Step
  alias Fizz.Workflows.Store.{Options, SqliteStore}
  alias Fizz.Workflows.{StepExecutionTrace, WorkflowDefinitionVersion, WorkflowRun}
  alias Runic.Workflow.{ComponentAdded, RunnableCompleted, RunnableDispatched, RunnableFailed}

  def list(%WorkflowRun{} = run, %WorkflowDefinitionVersion{} = version) do
    with {:ok, store_state} <- init_run_store(run),
         {:ok, event_log} <- load_run_event_log(run, store_state) do
      {:ok, build_step_executions(run, version, event_log, store_state)}
    else
      {:error, :checkpoint_not_found} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  def load_io(%WorkflowRun{} = run, %WorkflowDefinitionVersion{} = version, step_execution_id)
      when is_binary(step_execution_id) do
    with {:ok, store_state} <- init_run_store(run),
         {:ok, event_log} <- load_run_event_log(run, store_state),
         {:ok, step_execution} <-
           find_step_execution(run, version, event_log, store_state, step_execution_id) do
      metadata = Map.get(step_execution, :metadata, %{})

      {:ok,
       %{
         step_execution_id: step_execution.id,
         execution_id: step_execution.execution_id,
         step_id: step_execution.step_id,
         attempt: step_execution.attempt,
         input_data:
           load_fact_value(
             Map.get(metadata, :input_fact_hash),
             store_state,
             Map.get(step_execution, :input_data)
           ),
         output_data:
           load_fact_value(
             Map.get(metadata, :output_fact_hash),
             store_state,
             Map.get(step_execution, :output_data)
           )
       }}
    end
  end

  defp init_run_store(run) do
    SqliteStore.init(run.id, Options.for_run(run, 0))
  end

  defp load_run_event_log(run, store_state) do
    case SqliteStore.load(run.id, store_state) do
      {:ok, event_log} -> {:ok, event_log}
      {:error, :not_found} -> {:error, :checkpoint_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp find_step_execution(run, version, event_log, store_state, step_execution_id) do
    run
    |> build_step_executions(version, event_log, store_state)
    |> Enum.find(&(&1.id == step_execution_id))
    |> case do
      nil -> {:error, :step_execution_not_found}
      step_execution -> {:ok, step_execution}
    end
  end

  defp build_step_executions(run, version, event_log, store_state) do
    step_type_by_id =
      Map.new(version.steps, fn %Step{id: step_id, type_id: type_id} -> {step_id, type_id} end)

    node_name_by_hash = node_name_by_hash(event_log)
    splitter_dispatch_by_runnable = splitter_dispatch_by_runnable(event_log, step_type_by_id)

    event_log
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {event, index}, acc ->
      reduce_step_execution_event(
        acc,
        event,
        index,
        run,
        step_type_by_id,
        node_name_by_hash,
        splitter_dispatch_by_runnable,
        store_state
      )
    end)
    |> Map.values()
    |> Enum.sort_by(&step_execution_sort_key/1)
  end

  defp reduce_step_execution_event(
         acc,
         %RunnableDispatched{} = event,
         index,
         run,
         step_type_by_id,
         _node_name_by_hash,
         _splitter_dispatch_by_runnable,
         _store_state
       ) do
    with {:ok, step_id} <- StepExecutionTrace.logical_step_id(event.node_name, step_type_by_id) do
      step_execution_id = step_execution_id(run.id, event.runnable_id, event.attempt)
      started_at = approximate_event_time(run, index)
      iteration = StepExecutionTrace.fact_iteration_metadata(event.input_fact)

      Map.put(acc, step_execution_id, %{
        id: step_execution_id,
        execution_id: run.id,
        step_id: step_id,
        step_type_id: Map.get(step_type_by_id, step_id, "unknown"),
        status: "running",
        input_data: fact_value(event.input_fact),
        output_data: nil,
        output_item_count: nil,
        item_index: iteration.item_index,
        items_total: iteration.items_total,
        error: nil,
        attempt: event.attempt,
        retry_of_id: nil,
        duration_us: nil,
        queued_at: encode_datetime(started_at),
        started_at: encode_datetime(started_at),
        completed_at: nil,
        metadata: %{
          input_fact_hash: fact_hash(event.input_fact),
          output_fact_hash: nil,
          output_summary: nil
        },
        inserted_at: encode_datetime(started_at)
      })
    else
      :error -> acc
    end
  end

  defp reduce_step_execution_event(
         acc,
         %RunnableCompleted{} = event,
         index,
         run,
         step_type_by_id,
         node_name_by_hash,
         splitter_dispatch_by_runnable,
         store_state
       ) do
    case splitter_fan_out_step_id(event, node_name_by_hash, step_type_by_id) do
      {:ok, step_id} ->
        build_splitter_iteration_executions(
          acc,
          event,
          index,
          run,
          step_id,
          splitter_dispatch_by_runnable,
          store_state
        )

      :error ->
        step_execution_id = step_execution_id(run.id, event.runnable_id, event.attempt)
        existing = Map.get(acc, step_execution_id)

        with {:ok, step_id} <-
               completed_step_id(existing, event, node_name_by_hash, step_type_by_id) do
          input_fact_hash = existing_input_fact_hash(existing, event)
          output = fact_value(event.result_fact)
          completed_at = approximate_event_time(run, index)

          started_at =
            existing_timestamp(existing, :started_at, approximate_event_time(run, index))

          iteration = completed_iteration_metadata(existing, event.result_fact)

          Map.put(acc, step_execution_id, %{
            id: step_execution_id,
            execution_id: run.id,
            step_id: step_id,
            step_type_id: Map.get(step_type_by_id, step_id, "unknown"),
            status: "completed",
            input_data: existing_input_data(existing, input_fact_hash, store_state),
            output_data: output,
            output_item_count: output_item_count(output),
            item_index: iteration.item_index,
            items_total: iteration.items_total,
            error: nil,
            attempt: event.attempt,
            retry_of_id: nil,
            duration_us: event_duration_us(event),
            queued_at: existing_timestamp(existing, :queued_at, started_at),
            started_at: encode_datetime(started_at),
            completed_at: encode_datetime(completed_at),
            metadata: %{
              input_fact_hash: input_fact_hash,
              output_fact_hash: fact_hash(event.result_fact),
              output_summary: truncate_output(output)
            },
            inserted_at: existing_timestamp(existing, :inserted_at, started_at)
          })
        else
          :error -> acc
        end
    end
  end

  defp reduce_step_execution_event(
         acc,
         %RunnableFailed{} = event,
         index,
         run,
         step_type_by_id,
         node_name_by_hash,
         _splitter_dispatch_by_runnable,
         store_state
       ) do
    step_execution_id = step_execution_id(run.id, event.runnable_id, event.attempts - 1)
    existing = Map.get(acc, step_execution_id)

    with {:ok, step_id} <- failed_step_id(existing, event, node_name_by_hash, step_type_by_id) do
      started_at = existing_timestamp(existing, :started_at, approximate_event_time(run, index))
      input_fact_hash = existing_input_fact_hash(existing, nil)
      iteration = existing_iteration_metadata(existing)

      Map.put(acc, step_execution_id, %{
        id: step_execution_id,
        execution_id: run.id,
        step_id: step_id,
        step_type_id: Map.get(step_type_by_id, step_id, "unknown"),
        status: "failed",
        input_data: existing_input_data(existing, input_fact_hash, store_state),
        output_data: Map.get(existing || %{}, :output_data),
        output_item_count: nil,
        item_index: iteration.item_index,
        items_total: iteration.items_total,
        error: inspect(event.error),
        attempt: max(event.attempts - 1, 0),
        retry_of_id: nil,
        duration_us: event_duration_us(event) || Map.get(existing || %{}, :duration_us),
        queued_at: existing_timestamp(existing, :queued_at, started_at),
        started_at: encode_datetime(started_at),
        completed_at: encode_datetime(approximate_event_time(run, index)),
        metadata: Map.get(existing || %{}, :metadata, %{input_fact_hash: input_fact_hash}),
        inserted_at: existing_timestamp(existing, :inserted_at, started_at)
      })
    else
      :error -> acc
    end
  end

  defp reduce_step_execution_event(
         acc,
         _event,
         _index,
         _run,
         _step_type_by_id,
         _node_name_by_hash,
         _splitter_dispatch_by_runnable,
         _store_state
       ),
       do: acc

  defp node_name_by_hash(event_log) do
    Enum.reduce(event_log, %{}, fn
      %ComponentAdded{hash: hash, name: name}, acc when not is_nil(hash) and not is_nil(name) ->
        Map.put(acc, hash, name)

      %RunnableDispatched{node_hash: hash, node_name: name}, acc
      when not is_nil(hash) and not is_nil(name) ->
        Map.put(acc, hash, name)

      _event, acc ->
        acc
    end)
  end

  defp splitter_dispatch_by_runnable(event_log, step_type_by_id) do
    Enum.reduce(event_log, %{}, fn
      %RunnableDispatched{} = event, acc ->
        case StepExecutionTrace.splitter_fan_out_step_id(event.node_name, step_type_by_id) do
          {:ok, _step_id} ->
            Map.put(acc, {event.runnable_id, event.attempt}, %{
              input_data: fact_value(event.input_fact),
              input_fact_hash: fact_hash(event.input_fact)
            })

          :error ->
            acc
        end

      _event, acc ->
        acc
    end)
  end

  defp completed_step_id(existing, event, node_name_by_hash, step_type_by_id) do
    case existing do
      %{step_id: step_id} when is_binary(step_id) ->
        {:ok, step_id}

      _ ->
        event.node_hash
        |> then(&Map.get(node_name_by_hash, &1))
        |> StepExecutionTrace.logical_step_id(step_type_by_id)
    end
  end

  defp failed_step_id(existing, event, node_name_by_hash, step_type_by_id) do
    case existing do
      %{step_id: step_id} when is_binary(step_id) ->
        {:ok, step_id}

      _ ->
        event.node_hash
        |> then(&Map.get(node_name_by_hash, &1))
        |> StepExecutionTrace.logical_step_id(step_type_by_id)
    end
  end

  defp step_execution_id(run_id, runnable_id, attempt) do
    "#{run_id}:#{runnable_id}:#{attempt}"
  end

  defp approximate_event_time(run, index) do
    base_time = run.started_at || run.inserted_at || DateTime.utc_now()
    DateTime.add(base_time, index, :microsecond)
  end

  defp existing_timestamp(nil, _field, %DateTime{} = fallback), do: encode_datetime(fallback)
  defp existing_timestamp(nil, _field, fallback), do: encode_datetime(fallback)

  defp existing_timestamp(existing, field, %DateTime{} = fallback) do
    Map.get(existing, field) || encode_datetime(fallback)
  end

  defp existing_timestamp(existing, field, fallback) do
    Map.get(existing, field) || encode_datetime(fallback)
  end

  defp existing_input_fact_hash(%{metadata: metadata}, _event) when is_map(metadata) do
    Map.get(metadata, :input_fact_hash)
  end

  defp existing_input_fact_hash(_existing, %RunnableCompleted{result_fact: result_fact}) do
    fact_parent_hash(result_fact)
  end

  defp existing_input_fact_hash(_existing, _event), do: nil

  defp existing_input_data(%{input_data: input_data}, _input_fact_hash, _store_state)
       when not is_nil(input_data),
       do: input_data

  defp existing_input_data(_existing, input_fact_hash, store_state) do
    load_fact_value(input_fact_hash, store_state, nil)
  end

  defp load_fact_value(nil, _store_state, fallback), do: fallback

  defp load_fact_value(hash, store_state, fallback) when not is_nil(hash) do
    case SqliteStore.load_fact(hash, store_state) do
      {:ok, value} -> value
      {:error, _reason} -> fallback
    end
  end

  defp load_fact_value(_hash, _store_state, fallback), do: fallback

  defp fact_hash(%{hash: hash}) when not is_nil(hash), do: hash
  defp fact_hash(_fact), do: nil

  defp fact_value(%{value: value}), do: value
  defp fact_value(_fact), do: nil

  defp output_item_count(nil), do: nil
  defp output_item_count(output) when is_list(output), do: length(output)
  defp output_item_count(_output), do: 1

  defp splitter_fan_out_step_id(
         %RunnableCompleted{node_hash: node_hash},
         node_name_by_hash,
         step_type_by_id
       ) do
    node_hash
    |> then(&Map.get(node_name_by_hash, &1))
    |> StepExecutionTrace.splitter_fan_out_step_id(step_type_by_id)
  end

  defp build_splitter_iteration_executions(
         acc,
         event,
         index,
         run,
         step_id,
         splitter_dispatch_by_runnable,
         store_state
       ) do
    completed_at = approximate_event_time(run, index)
    emitted_facts = splitter_emitted_facts(event.result_fact)
    items_total = length(emitted_facts)
    per_item_duration = per_item_duration_us(event_duration_us(event), items_total)
    dispatch = Map.get(splitter_dispatch_by_runnable, {event.runnable_id, event.attempt}, %{})

    Enum.reduce(Enum.with_index(emitted_facts), acc, fn {fact, fallback_index}, acc ->
      item_index = StepExecutionTrace.fact_item_index(fact) || fallback_index

      step_execution_id =
        step_execution_id(run.id, "#{event.runnable_id}:#{item_index}", event.attempt)

      input_fact_hash =
        Map.get(dispatch, :input_fact_hash) || fan_out_input_fact_hash(fact)

      input_data =
        Map.get(dispatch, :input_data) || load_fact_value(input_fact_hash, store_state, nil)

      started_at = DateTime.add(completed_at, -per_item_duration, :microsecond)

      Map.put(acc, step_execution_id, %{
        id: step_execution_id,
        execution_id: run.id,
        step_id: step_id,
        step_type_id: "splitter",
        status: "completed",
        input_data: input_data,
        output_data: fact_value(fact),
        output_item_count: 1,
        item_index: item_index,
        items_total: StepExecutionTrace.fact_items_total(fact) || items_total,
        error: nil,
        attempt: event.attempt,
        retry_of_id: nil,
        duration_us: per_item_duration,
        queued_at: encode_datetime(started_at),
        started_at: encode_datetime(started_at),
        completed_at: encode_datetime(completed_at),
        metadata: %{
          input_fact_hash: input_fact_hash,
          output_fact_hash: fact_hash(fact),
          output_summary: truncate_output(fact_value(fact))
        },
        inserted_at: encode_datetime(started_at)
      })
    end)
  end

  defp splitter_emitted_facts(result) when is_list(result) do
    Enum.filter(result, &match?(%Runic.Workflow.Fact{}, &1))
  end

  defp splitter_emitted_facts(_result), do: []

  defp fact_parent_hash(%{ancestry: {_node_hash, fact_hash}}) when not is_nil(fact_hash),
    do: fact_hash

  defp fact_parent_hash(_fact), do: nil

  defp fan_out_input_fact_hash(%{ancestry: {_fan_out_hash, input_fact_hash}})
       when not is_nil(input_fact_hash),
       do: input_fact_hash

  defp fan_out_input_fact_hash(_fact), do: nil

  defp completed_iteration_metadata(
         %{item_index: item_index, items_total: items_total},
         _result_fact
       ) do
    %{item_index: item_index, items_total: items_total}
  end

  defp completed_iteration_metadata(_existing, result_fact) do
    StepExecutionTrace.fact_iteration_metadata(result_fact)
  end

  defp existing_iteration_metadata(%{item_index: item_index, items_total: items_total}) do
    %{item_index: item_index, items_total: items_total}
  end

  defp existing_iteration_metadata(_existing) do
    %{item_index: nil, items_total: nil}
  end

  defp per_item_duration_us(duration_us, items_total)
       when is_integer(duration_us) and duration_us >= 0 and is_integer(items_total) and
              items_total > 0 do
    max(div(duration_us, items_total), 0)
  end

  defp per_item_duration_us(_duration_us, _items_total), do: 0

  defp duration_us_from_ms(duration_ms) when is_integer(duration_ms) and duration_ms >= 0,
    do: duration_ms * 1_000

  defp duration_us_from_ms(_duration_ms), do: nil

  defp event_duration_us(%RunnableCompleted{} = event) do
    case Map.get(event, :duration_us) do
      duration_us when is_integer(duration_us) and duration_us >= 0 ->
        duration_us

      _ ->
        duration_us_from_ms(event.duration_ms)
    end
  end

  defp event_duration_us(%RunnableFailed{} = event) do
    case Map.get(event, :duration_us) do
      duration_us when is_integer(duration_us) and duration_us >= 0 -> duration_us
      _ -> nil
    end
  end

  defp truncate_output(output) do
    rendered = inspect(output, pretty: true, limit: :infinity, printable_limit: :infinity)

    if byte_size(rendered) <= 1_024 do
      rendered
    else
      binary_part(rendered, 0, 1_024) <> "..."
    end
  end

  defp step_execution_sort_key(step_execution) do
    [
      Map.get(step_execution, :started_at),
      Map.get(step_execution, :completed_at),
      Map.get(step_execution, :inserted_at)
    ]
    |> Enum.find(&(is_binary(&1) and byte_size(&1) > 0))
    |> case do
      nil -> ""
      value -> value
    end
  end

  defp encode_datetime(nil), do: nil
  defp encode_datetime(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp encode_datetime(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp encode_datetime(value), do: value
end
