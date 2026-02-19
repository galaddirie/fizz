defmodule FizzWeb.WorkflowLive.Paths do
  @moduledoc false
  use FizzWeb, :verified_routes

  def workflows_index_path(%{workspace: %{id: workspace_id}}),
    do: ~p"/workspaces/#{workspace_id}/workflows"

  def workflow_show_path(%{workspace: %{id: workspace_id}}, workflow_id),
    do: ~p"/workspaces/#{workspace_id}/workflows/#{workflow_id}"

  def workflow_edit_path(%{workspace: %{id: workspace_id}}, workflow_id),
    do: ~p"/workspaces/#{workspace_id}/workflows/#{workflow_id}/edit"

  def workflow_edit_path(%{workspace: %{id: workspace_id}}, workflow_id, debug_execution_id),
    do:
      ~p"/workspaces/#{workspace_id}/workflows/#{workflow_id}/edit?debug_execution_id=#{debug_execution_id}"

  def workflow_revisions_path(%{workspace: %{id: workspace_id}}, workflow_id),
    do: ~p"/workspaces/#{workspace_id}/workflows/#{workflow_id}/revisions"

  def workflow_revisions_path(%{workspace: %{id: workspace_id}}, workflow_id, %{undo: depth}),
    do: ~p"/workspaces/#{workspace_id}/workflows/#{workflow_id}/revisions?undo=#{depth}"

  def workflow_revisions_path(%{workspace: %{id: workspace_id}}, workflow_id, %{
        version: version_id
      }),
      do: ~p"/workspaces/#{workspace_id}/workflows/#{workflow_id}/revisions?version=#{version_id}"

  def execution_show_path(%{workspace: %{id: workspace_id}}, workflow_id, execution_id),
    do: ~p"/workspaces/#{workspace_id}/workflows/#{workflow_id}/execution/#{execution_id}"
end
