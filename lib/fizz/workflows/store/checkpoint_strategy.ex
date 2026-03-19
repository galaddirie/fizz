defmodule Fizz.Workflows.Store.CheckpointStrategy do
  @moduledoc false

  @spec should_checkpoint?(
          :every_cycle | :on_complete | :manual | {:every_n, pos_integer()},
          term()
        ) ::
          boolean()
  def should_checkpoint?(:every_cycle, _event), do: true

  def should_checkpoint?({:every_n, n}, %{cycle_count: cycle_count})
      when is_integer(n) and n > 0 and is_integer(cycle_count) and cycle_count > 0 do
    rem(cycle_count, n) == 0
  end

  def should_checkpoint?(:on_complete, %{status: status})
      when status in [:completed, "completed"],
      do: true

  def should_checkpoint?(:on_complete, :completed), do: true
  def should_checkpoint?(:manual, _event), do: false
  def should_checkpoint?({:every_n, _n}, _event), do: false
  def should_checkpoint?(:on_complete, _event), do: false
end
