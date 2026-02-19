defmodule Fizz.Collaboration.EditSession.UndoEntry do
  @moduledoc """
  Represents a grouped undo/redo entry for a single user.
  """

  defstruct [
    :id,
    :group_id,
    :label,
    :timestamp,
    :user_id,
    operations: [],
    inverse_ops: []
  ]
end
