defmodule FizzWeb.WorkflowLive.Edit.PresenceFormatter do
  @moduledoc false

  @spec format(map()) :: [map()]
  def format(presence_list) when is_map(presence_list) do
    Enum.map(presence_list, fn {user_id, %{metas: metas}} ->
      meta = List.first(metas) || %{}

      %{
        user: %{
          id: user_id,
          name: get_in(meta, [:user, :name]),
          email: get_in(meta, [:user, :email])
        },
        cursor: meta[:cursor],
        dragging_steps: meta[:dragging_steps],
        selected_steps: meta[:selected_steps] || [],
        focused_step: meta[:focused_step]
      }
    end)
  end

  def format(_presence_list), do: []
end
