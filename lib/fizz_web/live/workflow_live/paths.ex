defmodule FizzWeb.WorkflowLive.Paths do
  @moduledoc false
  use FizzWeb, :verified_routes

  def workflows_index_path(%{workspace: %{id: workspace_id}}),
    do: ~p"/workspaces/#{workspace_id}/workflows"

  def workflow_show_path(%{workspace: %{id: workspace_id}}, workflow_id),
    do: ~p"/workspaces/#{workspace_id}/workflows/#{workflow_id}"
end
