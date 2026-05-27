defmodule Fizz.Workflows.Runner.OperationRetry do
  @moduledoc false

  alias Fizz.Integrations.{Catalog, OperationError, RetryPolicy}
  alias Fizz.Workflows.{DurableTimer, StepExecutionError}
  alias Runic.Workflow.{Fact, Invokable, Runnable}

  @format "operation_retry_v1"

  @type retry :: %{
          operation_id: String.t(),
          operation_version: pos_integer() | nil,
          error: OperationError.t(),
          failed_attempt: pos_integer(),
          next_attempt: non_neg_integer(),
          delay_ms: non_neg_integer(),
          timer_payload: map()
        }

  @spec next_retry(Runnable.t(), term(), non_neg_integer()) :: {:ok, retry()} | :halt
  def next_retry(%Runnable{} = runnable, error, attempt_index)
      when is_integer(attempt_index) and attempt_index >= 0 do
    with {:ok, step_error} <- step_error(error),
         {:ok, operation_id} <- operation_id(step_error),
         {:ok, operation} <- Catalog.operation(operation_id),
         %RetryPolicy{} = policy <- operation.retry,
         failed_attempt <- attempt_index + 1,
         true <- RetryPolicy.retryable?(policy, step_error.reason, failed_attempt),
         delay_ms when is_integer(delay_ms) <-
           RetryPolicy.next_delay_ms(policy, step_error.reason, failed_attempt) do
      next_attempt = failed_attempt

      {:ok,
       %{
         operation_id: operation.id,
         operation_version: operation.version,
         error: step_error.reason,
         failed_attempt: failed_attempt,
         next_attempt: next_attempt,
         delay_ms: delay_ms,
         timer_payload:
           timer_payload(runnable, operation, step_error.reason, next_attempt, delay_ms)
       }}
    else
      _reason -> :halt
    end
  end

  def next_retry(_runnable, _error, _attempt_index), do: :halt

  @spec timer?(DurableTimer.t()) :: boolean()
  def timer?(%DurableTimer{payload: %{"format" => @format}}), do: true
  def timer?(_timer), do: false

  @spec timer_name(Runnable.t()) :: String.t()
  def timer_name(%Runnable{id: runnable_id}), do: "operation_retry:#{runnable_id}"

  @spec retry_step_id(Runnable.t()) :: String.t()
  def retry_step_id(%Runnable{node: %{name: name}}) when is_atom(name), do: Atom.to_string(name)
  def retry_step_id(%Runnable{node: %{name: name}}) when is_binary(name), do: name
  def retry_step_id(%Runnable{id: runnable_id}), do: to_string(runnable_id)

  @spec decode_timer(DurableTimer.t(), map()) ::
          {:ok, %{runnable: Runnable.t(), attempt: non_neg_integer()}} | {:error, term()}
  def decode_timer(%DurableTimer{} = timer, workflow) do
    with {:ok, data} <- decode_payload(timer.payload),
         %{} = node <- Map.get(workflow.graph.vertices, data.node_hash),
         %Fact{} = fact <- Map.get(workflow.graph.vertices, data.input_fact_hash),
         {:ok, %Runnable{} = runnable} <- Invokable.prepare(node, workflow, fact),
         attempt when is_integer(attempt) and attempt >= 0 <- Map.get(data, :attempt) do
      {:ok, %{runnable: runnable, attempt: attempt}}
    else
      _reason -> {:error, :invalid_operation_retry_payload}
    end
  end

  @spec run_error_payload(retry(), DateTime.t()) :: map()
  def run_error_payload(retry, %DateTime{} = retry_at) when is_map(retry) do
    %{
      type: "operation_retry",
      operation_id: retry.operation_id,
      operation_version: retry.operation_version,
      failed_attempt: retry.failed_attempt,
      next_attempt: retry.next_attempt,
      delay_ms: retry.delay_ms,
      retry_at: DateTime.to_iso8601(retry_at),
      error: operation_error_payload(retry.error)
    }
  end

  @spec operation_error_payload(OperationError.t()) :: map()
  def operation_error_payload(%OperationError{} = error) do
    %{
      type: "operation_error",
      code: stringify(error.code),
      category: stringify(error.category),
      message: error.message,
      status: error.status,
      source: stringify(error.source),
      retry_after_ms: error.retry_after_ms,
      retryable: error.retryable?,
      details: stringify_values(error.details || %{})
    }
  end

  def operation_error_payload(error) do
    %{type: "operation_error", message: inspect(error)}
  end

  defp step_error(%StepExecutionError{reason: %OperationError{} = reason} = error) do
    {:ok, %{error | reason: reason}}
  end

  defp step_error(_error), do: :error

  defp operation_id(%StepExecutionError{operation_id: operation_id})
       when is_binary(operation_id) and operation_id != "",
       do: {:ok, operation_id}

  defp operation_id(%StepExecutionError{reason: %OperationError{source: source}})
       when is_binary(source) and source != "",
       do: {:ok, source}

  defp operation_id(_error), do: :error

  defp timer_payload(
         %Runnable{} = runnable,
         operation,
         %OperationError{} = error,
         attempt,
         delay_ms
       ) do
    data = %{
      node_hash: Map.fetch!(runnable.node, :hash),
      input_fact_hash: runnable.input_fact.hash,
      operation_id: operation.id,
      operation_version: operation.version,
      attempt: attempt,
      delay_ms: delay_ms,
      error: operation_error_payload(error)
    }

    %{
      "format" => @format,
      "data" => data |> :erlang.term_to_binary([:compressed]) |> Base.encode64()
    }
  end

  defp decode_payload(%{"format" => @format, "data" => encoded}) when is_binary(encoded) do
    with {:ok, binary} <- Base.decode64(encoded),
         data when is_map(data) <- :erlang.binary_to_term(binary) do
      {:ok, data}
    else
      _reason -> {:error, :invalid_operation_retry_payload}
    end
  end

  defp decode_payload(_payload), do: {:error, :invalid_operation_retry_payload}

  defp stringify(nil), do: nil
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: inspect(value)

  defp stringify_values(value) when is_map(value) do
    Map.new(value, fn {key, nested_value} -> {to_string(key), stringify_values(nested_value)} end)
  end

  defp stringify_values(value) when is_list(value), do: Enum.map(value, &stringify_values/1)

  defp stringify_values(value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: value

  defp stringify_values(nil), do: nil
  defp stringify_values(value), do: stringify(value)
end
