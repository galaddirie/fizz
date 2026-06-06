defmodule Fizz.Workflows.RetryPolicy do
  @moduledoc """
  Declarative retry metadata for executable workflow steps.
  """

  alias Fizz.Workflows.StepError

  @type backoff :: :none | :linear | :exponential
  @type retry_match :: StepError.category() | atom()

  defstruct max_attempts: 1,
            backoff: :none,
            initial_delay_ms: 1_000,
            max_delay_ms: 60_000,
            retry_on: [:rate_limit, :network, :transient]

  @type t :: %__MODULE__{
          max_attempts: pos_integer(),
          backoff: backoff(),
          initial_delay_ms: pos_integer(),
          max_delay_ms: pos_integer(),
          retry_on: [retry_match()]
        }

  @spec validate!(t()) :: t()
  def validate!(%__MODULE__{} = policy) do
    case validate(policy) do
      :ok -> policy
      {:error, reason} -> raise ArgumentError, "invalid retry policy: #{inspect(reason)}"
    end
  end

  def validate!(policy) do
    raise ArgumentError, "invalid retry policy: #{inspect(policy)}"
  end

  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%__MODULE__{
        max_attempts: max_attempts,
        backoff: backoff,
        initial_delay_ms: initial_delay_ms,
        max_delay_ms: max_delay_ms,
        retry_on: retry_on
      }) do
    with :ok <- positive_integer(max_attempts, :max_attempts),
         :ok <- supported_backoff(backoff),
         :ok <- positive_integer(initial_delay_ms, :initial_delay_ms),
         :ok <- positive_integer(max_delay_ms, :max_delay_ms),
         :ok <- retry_on_atoms(retry_on) do
      :ok
    end
  end

  def validate(policy), do: {:error, {:invalid_policy, policy}}

  @spec retryable?(t(), StepError.t(), pos_integer()) :: boolean()
  def retryable?(%__MODULE__{} = policy, %StepError{} = error, attempt)
      when is_integer(attempt) and attempt > 0 do
    attempt < policy.max_attempts and error.retryable? and
      (error.category in policy.retry_on or error.code in policy.retry_on)
  end

  def retryable?(_policy, _error, _attempt), do: false

  @spec next_delay_ms(t(), StepError.t(), pos_integer()) :: non_neg_integer() | nil
  def next_delay_ms(%__MODULE__{} = policy, %StepError{} = error, attempt) do
    if retryable?(policy, error, attempt) do
      case error.retry_after_ms do
        retry_after_ms when is_integer(retry_after_ms) and retry_after_ms >= 0 ->
          min(retry_after_ms, policy.max_delay_ms)

        _ ->
          computed_delay_ms(policy, attempt)
      end
    end
  end

  defp computed_delay_ms(%__MODULE__{backoff: :none}, _attempt), do: 0

  defp computed_delay_ms(%__MODULE__{backoff: :linear} = policy, attempt) do
    min(policy.initial_delay_ms * attempt, policy.max_delay_ms)
  end

  defp computed_delay_ms(%__MODULE__{backoff: :exponential} = policy, attempt) do
    multiplier = Integer.pow(2, attempt - 1)
    min(policy.initial_delay_ms * multiplier, policy.max_delay_ms)
  end

  defp positive_integer(value, _field) when is_integer(value) and value > 0, do: :ok
  defp positive_integer(value, field), do: {:error, {field, value}}

  defp supported_backoff(backoff) when backoff in [:none, :linear, :exponential], do: :ok
  defp supported_backoff(backoff), do: {:error, {:backoff, backoff}}

  defp retry_on_atoms(retry_on) when is_list(retry_on) do
    case Enum.all?(retry_on, &is_atom/1) do
      true -> :ok
      false -> {:error, {:retry_on, retry_on}}
    end
  end

  defp retry_on_atoms(retry_on), do: {:error, {:retry_on, retry_on}}
end
