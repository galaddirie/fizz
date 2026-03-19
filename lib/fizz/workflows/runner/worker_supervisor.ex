defmodule Fizz.Workflows.Runner.WorkerSupervisor do
  @moduledoc """
  Dynamic supervisor for workflow run workers.

  Each active `WorkflowRun` gets its own worker process under this supervisor.
  `max_children` provides node-level backpressure so a single node cannot start
  unbounded concurrent workflow executions.
  """

  use DynamicSupervisor

  alias Fizz.Workflows.Runner.Worker

  @default_max_children 1_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    max_children =
      Keyword.get(
        opts,
        :max_children,
        Application.get_env(:fizz, __MODULE__, [])
        |> Keyword.get(:max_children, @default_max_children)
      )

    DynamicSupervisor.init(strategy: :one_for_one, max_children: max_children)
  end

  @doc """
  Starts a workflow run worker under the configured dynamic supervisor.
  """
  def start_worker(opts) when is_list(opts) do
    supervisor = Keyword.get(opts, :supervisor, __MODULE__)
    worker_opts = Keyword.delete(opts, :supervisor)
    DynamicSupervisor.start_child(supervisor, {Worker, worker_opts})
  end
end
