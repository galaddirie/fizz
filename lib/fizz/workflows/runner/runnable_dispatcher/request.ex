defmodule Fizz.Workflows.Runner.RunnableDispatcher.Request do
  @moduledoc """
  Immutable request handed from a workflow worker to the global runnable dispatcher.
  """

  alias Runic.Workflow.Runnable

  @enforce_keys [:ref, :run_id, :worker_pid, :runnable, :enqueued_at_us]
  defstruct [:ref, :run_id, :worker_pid, :runnable, :enqueued_at_us]

  @type t :: %__MODULE__{
          ref: reference(),
          run_id: String.t(),
          worker_pid: pid(),
          runnable: Runnable.t(),
          enqueued_at_us: integer()
        }

  @spec new(String.t(), pid(), Runnable.t()) :: t()
  def new(run_id, worker_pid, %Runnable{} = runnable)
      when is_binary(run_id) and is_pid(worker_pid) do
    %__MODULE__{
      ref: make_ref(),
      run_id: run_id,
      worker_pid: worker_pid,
      runnable: runnable,
      enqueued_at_us: System.monotonic_time(:microsecond)
    }
  end
end
