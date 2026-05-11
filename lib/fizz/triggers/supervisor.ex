defmodule Fizz.Triggers.Supervisor do
  @moduledoc """
  Supervises trigger registration infrastructure.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    Supervisor.init(
      [
        Fizz.Triggers.Registry,
        {Registry, keys: :unique, name: Fizz.Triggers.SourceRegistry},
        {DynamicSupervisor, name: Fizz.Triggers.SourceSupervisor, strategy: :one_for_one},
        Fizz.Triggers.SourceReconciler
      ],
      strategy: :rest_for_one
    )
  end
end
