defmodule FizzWeb.WorkflowLive.Edit.Command do
  @moduledoc false

  @commands MapSet.new([
              "add_step",
              "duplicate_steps",
              "move_step",
              "move_steps",
              "tidy_layout",
              "update_step",
              "remove_step",
              "add_group",
              "update_group",
              "remove_group",
              "set_group_membership",
              "commit_drag_layout",
              "add_connection",
              "remove_connection",
              "undo",
              "redo",
              "navigate_revisions",
              "pin_output",
              "unpin_output",
              "disable_step",
              "enable_step",
              "mouse_move",
              "selection_changed",
              "save_workflow",
              "publish_workflow",
              "run_test",
              "run_node",
              "toggle_webhook_test",
              "cancel_execution",
              "preview_expression"
            ])

  @spec parse(map()) :: {:ok, String.t(), map()} | {:error, :invalid}
  def parse(%{"type" => type, "payload" => payload})
      when is_binary(type) and is_map(payload) do
    {:ok, type, payload}
  end

  def parse(%{type: type, payload: payload}) when is_binary(type) and is_map(payload) do
    {:ok, type, payload}
  end

  def parse(%{"type" => type}) when is_binary(type), do: {:ok, type, %{}}
  def parse(%{type: type}) when is_binary(type), do: {:ok, type, %{}}
  def parse(_params), do: {:error, :invalid}

  @spec valid?(String.t()) :: boolean()
  def valid?(command) when is_binary(command), do: MapSet.member?(@commands, command)
  def valid?(_command), do: false
end
