defmodule Fizz.Collaboration.PreviewExecution do
  @moduledoc """
  Builds and runs preview executions that incorporate editor state
  (pins, disabled steps, partial execution).
  """

  alias Fizz.Collaboration.EditSession.Server, as: EditServer
  alias Fizz.Collaboration.EditorState
  alias Fizz.Graph
  alias Fizz.Runtime.ExecutionContext
  alias Fizz.Runtime.RunicAdapter
  alias Fizz.Executions
  alias Fizz.Accounts.Scope

  @type execution_mode :: :full | :from_step | :to_step | :selected

  @type preview_opts :: [
          mode: execution_mode(),
          target_steps: [String.t()],
          input_data: map()
        ]

  @doc """
  Run a preview execution with editor state applied.

  This:
  1. Gets current draft and editor state from the session
  2. Applies disabled steps (skip or exclude)
  3. Injects pinned outputs
  4. Builds execution subgraph based on mode
  5. Runs the execution
  """
  @spec run(String.t(), Scope.t(), preview_opts()) ::
          {:ok, Executions.Execution.t()} | {:error, term()}
  def run(workflow_id, scope, opts \\ []) do
    mode = Keyword.get(opts, :mode, :full)
    target_steps = Keyword.get(opts, :target_steps, [])
    input_data = Keyword.get(opts, :input_data, %{})

    with {:ok, draft} <- get_draft(scope, workflow_id),
         {:ok, editor_state} <- get_editor_state(workflow_id),
         {:ok, effective_draft} <- apply_editor_state(draft, editor_state, mode, target_steps),
         {:ok, execution} <-
           create_preview_execution(workflow_id, scope, effective_draft, editor_state, input_data) do
      # Run synchronously for preview (could also queue)
      run_execution(execution, effective_draft, editor_state, scope)
    end
  end

  defp get_draft(scope, workflow_id) do
    case Fizz.Workflows.get_draft(scope, workflow_id) do
      {:error, :not_found} -> {:error, :draft_not_found}
      {:ok, draft} -> {:ok, draft}
    end
  end

  defp get_editor_state(workflow_id) do
    # Check if the session process exists
    case Registry.lookup(Fizz.Collaboration.EditSession.Registry, workflow_id) do
      [{_pid, _}] ->
        # Process exists, try to get state
        try do
          EditServer.get_editor_state(workflow_id)
        rescue
          _ -> {:ok, %EditorState{workflow_id: workflow_id}}
        end

      [] ->
        # No process, return default state
        {:ok, %EditorState{workflow_id: workflow_id}}
    end
  end

  defp apply_editor_state(draft, editor_state, mode, target_steps) do
    # 1. Remove or bypass disabled steps
    steps = apply_disabled_steps(draft.steps, editor_state)

    # 2. Filter connections for remaining steps
    step_ids = MapSet.new(Enum.map(steps, & &1.id))

    connections =
      Enum.filter(draft.connections, fn conn ->
        MapSet.member?(step_ids, conn.source_step_id) and
          MapSet.member?(step_ids, conn.target_step_id)
      end)

    # 3. Build subgraph based on execution mode
    {steps, connections} = build_subgraph(steps, connections, mode, target_steps)

    {:ok, %{draft | steps: steps, connections: connections}}
  end

  defp apply_disabled_steps(steps, editor_state) do
    # For now, just exclude disabled steps entirely
    # Could implement bypass mode here
    Enum.reject(steps, fn step ->
      MapSet.member?(editor_state.disabled_steps, step.id)
    end)
  end

  defp build_subgraph(steps, connections, :full, _targets) do
    {steps, connections}
  end

  defp build_subgraph(steps, connections, :from_step, [target_id]) do
    graph = Graph.from_workflow!(steps, connections)
    downstream = Graph.downstream(graph, target_id)
    keep_ids = MapSet.new([target_id | downstream])

    filtered_steps = Enum.filter(steps, &MapSet.member?(keep_ids, &1.id))

    filtered_connections =
      Enum.filter(connections, fn conn ->
        MapSet.member?(keep_ids, conn.source_step_id) and
          MapSet.member?(keep_ids, conn.target_step_id)
      end)

    {filtered_steps, filtered_connections}
  end

  defp build_subgraph(steps, connections, :to_step, [target_id]) do
    graph = Graph.from_workflow!(steps, connections)
    upstream = Graph.upstream(graph, target_id)
    keep_ids = MapSet.new([target_id | upstream])

    filtered_steps = Enum.filter(steps, &MapSet.member?(keep_ids, &1.id))

    filtered_connections =
      Enum.filter(connections, fn conn ->
        MapSet.member?(keep_ids, conn.source_step_id) and
          MapSet.member?(keep_ids, conn.target_step_id)
      end)

    {filtered_steps, filtered_connections}
  end

  defp build_subgraph(steps, connections, :selected, target_ids) do
    keep_ids = MapSet.new(target_ids)

    filtered_steps = Enum.filter(steps, &MapSet.member?(keep_ids, &1.id))

    filtered_connections =
      Enum.filter(connections, fn conn ->
        MapSet.member?(keep_ids, conn.source_step_id) and
          MapSet.member?(keep_ids, conn.target_step_id)
      end)

    {filtered_steps, filtered_connections}
  end

  defp build_subgraph(steps, connections, _unknown_mode, _targets) do
    # For unknown modes, default to full execution
    {steps, connections}
  end

  defp create_preview_execution(workflow_id, scope, _draft, editor_state, input_data) do
    # Include pinned outputs in the execution context
    initial_context =
      editor_state.pinned_outputs
      |> Enum.into(%{}, fn {step_id, data} -> {step_id, data} end)

    Executions.create_execution(
      scope,
      %{
        workflow_id: workflow_id,
        execution_type: :preview,
        trigger: %{type: :manual, data: input_data},
        context: initial_context,
        triggered_by_user_id: scope.user.id,
        metadata: %{
          extras: %{
            preview: true,
            pinned_steps: Map.keys(editor_state.pinned_outputs),
            disabled_steps: MapSet.to_list(editor_state.disabled_steps)
          }
        }
      }
    )
  end

  defp run_execution(execution, draft, editor_state, scope) do
    # Build Runic workflow with pinned outputs injected
    runic_workflow =
      RunicAdapter.to_runic_workflow(draft,
        execution_id: execution.id,
        step_outputs: editor_state.pinned_outputs
      )

    # Execute synchronously for preview
    case Runic.Workflow.react_until_satisfied(runic_workflow, %{}) do
      result_workflow ->
        context = extract_context(result_workflow, editor_state.pinned_outputs)

        case Executions.update_execution_status(scope, execution, :completed, context: context) do
          {:ok, updated_execution} -> {:ok, updated_execution}
          # Fallback to original if update fails
          {:error, _} -> {:ok, execution}
        end
    end
  rescue
    e ->
      Executions.update_execution_status(scope, execution, :failed, error: Exception.message(e))
      {:error, e}
  end

  defp extract_context(workflow, pinned_outputs) do
    ctx = ExecutionContext.from_runic_workflow(workflow)
    Map.merge(pinned_outputs || %{}, ctx.step_outputs)
  end
end
