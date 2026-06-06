defmodule Fizz.Workflows.Runner.RunnableConsumerSupervisor do
  @moduledoc """
  Supervises the bounded pool of GenStage runnable consumers.
  """

  use Supervisor

  alias Fizz.Workflows.Runner.RunnableConsumer
  alias Fizz.Workflows.Runner.RunnableDispatcher

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    max_concurrency =
      opts
      |> Keyword.get(:max_concurrency, System.schedulers_online() * 4)
      |> normalize_max_concurrency()

    producer = Keyword.get(opts, :dispatcher, RunnableDispatcher)
    task_supervisor = Keyword.get(opts, :task_supervisor, Fizz.Workflows.Runner.TaskSupervisor)

    children =
      for index <- 1..max_concurrency do
        Supervisor.child_spec(
          {RunnableConsumer, producer: producer, task_supervisor: task_supervisor},
          id: {RunnableConsumer, index}
        )
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp normalize_max_concurrency(value) when is_integer(value) and value > 0, do: value
  defp normalize_max_concurrency(_value), do: max(System.schedulers_online(), 1)
end
