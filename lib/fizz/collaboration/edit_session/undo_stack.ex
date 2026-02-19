defmodule Fizz.Collaboration.EditSession.UndoStack do
  @moduledoc """
  Per-user undo/redo stack with max size trimming.
  """

  alias Fizz.Collaboration.EditSession.UndoEntry

  defstruct undo: [], redo: [], max_size: 100

  @spec new(non_neg_integer()) :: %__MODULE__{}
  def new(max_size \\ 100) do
    %__MODULE__{max_size: max_size}
  end

  @spec push(%__MODULE__{}, UndoEntry.t()) :: %__MODULE__{}
  def push(%__MODULE__{} = stack, %UndoEntry{} = entry) do
    stack
    |> Map.put(:undo, [entry | stack.undo])
    |> Map.put(:redo, [])
    |> trim()
  end

  @spec pop_undo(%__MODULE__{}) :: {:ok, UndoEntry.t(), %__MODULE__{}} | :empty
  def pop_undo(%__MODULE__{undo: []}), do: :empty

  def pop_undo(%__MODULE__{} = stack) do
    [entry | rest] = stack.undo
    {:ok, entry, %{stack | undo: rest}}
  end

  @spec pop_redo(%__MODULE__{}) :: {:ok, UndoEntry.t(), %__MODULE__{}} | :empty
  def pop_redo(%__MODULE__{redo: []}), do: :empty

  def pop_redo(%__MODULE__{} = stack) do
    [entry | rest] = stack.redo
    {:ok, entry, %{stack | redo: rest}}
  end

  defp trim(%__MODULE__{} = stack) do
    if length(stack.undo) > stack.max_size do
      %{stack | undo: Enum.take(stack.undo, stack.max_size)}
    else
      stack
    end
  end
end
