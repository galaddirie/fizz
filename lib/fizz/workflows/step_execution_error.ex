defmodule Fizz.Workflows.StepExecutionError do
  @moduledoc """
  Exception raised at the Runic step boundary while preserving Fizz runtime metadata.

  Runic captures step exceptions into failed runnables. This wrapper keeps the
  original executor reason plus step and operation identifiers available to the
  workflow runner, which lets the runner make retry decisions without parsing a
  rendered exception string.
  """

  defexception [
    :reason,
    :step_id,
    :step_type_id,
    :operation_id,
    :operation_version,
    message: "step execution failed"
  ]

  @type t :: %__MODULE__{
          reason: term(),
          step_id: String.t() | nil,
          step_type_id: String.t() | nil,
          operation_id: String.t() | nil,
          operation_version: pos_integer() | nil,
          message: String.t()
        }

  @impl true
  def exception(opts) do
    reason = Keyword.get(opts, :reason)

    %__MODULE__{
      reason: reason,
      step_id: Keyword.get(opts, :step_id),
      step_type_id: Keyword.get(opts, :step_type_id),
      operation_id: Keyword.get(opts, :operation_id),
      operation_version: Keyword.get(opts, :operation_version),
      message: "step execution failed: #{inspect(reason)}"
    }
  end
end
