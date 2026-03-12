defmodule Fizz.Runtime.ExecutionContext do
  @moduledoc """
  Rich context for step execution within a Runic workflow.

  This struct provides all the context a step executor needs, built from
  Runic's workflow state and fact ancestry.

  ## Fields

  - `:execution_id` - The Fizz Execution record ID
  - `:workflow_id` - The source workflow ID
  - `:step_id` - The current step being executed
  - `:step_outputs` - Map of step_id => output for all completed steps
  - `:variables` - Workflow-level variables
  - `:metadata` - Execution metadata (trace_id, etc.)
  - `:scope` - Authenticated caller scope for execution-time integrations
  - `:input` - The input value for this step (from parent facts)
  """

  alias Fizz.Accounts.Scope

  @type t :: %__MODULE__{
          execution_id: String.t() | nil,
          workflow_id: String.t() | nil,
          step_id: String.t() | nil,
          step_outputs: %{String.t() => term()},
          variables: map(),
          metadata: map(),
          scope: Scope.t() | nil,
          input: term(),
          trigger: term(),
          trigger_type: atom() | nil,
          request: map()
        }

  defstruct [
    :execution_id,
    :workflow_id,
    :step_id,
    step_outputs: %{},
    variables: %{},
    metadata: %{},
    scope: nil,
    input: nil,
    trigger: nil,
    trigger_type: nil,
    request: %{}
  ]

  @doc """
  Builds an ExecutionContext from Runic workflow state.

  Extracts step outputs by traversing the workflow's graph for `:produced` edges.
  """
  @spec from_runic_workflow(Runic.Workflow.t(), map()) :: t()
  def from_runic_workflow(workflow, opts \\ %{}) do
    step_outputs = extract_step_outputs(workflow)

    %__MODULE__{
      execution_id: Map.get(opts, :execution_id),
      workflow_id: Map.get(opts, :workflow_id),
      step_id: Map.get(opts, :step_id),
      step_outputs: step_outputs,
      variables: Map.get(opts, :variables, %{}),
      metadata: Map.get(opts, :metadata, %{}),
      scope: Map.get(opts, :scope),
      input: Map.get(opts, :input),
      trigger: Map.get(opts, :trigger),
      trigger_type: Map.get(opts, :trigger_type),
      request: Map.get(opts, :request, %{})
    }
  end

  @doc """
  Creates a minimal context for testing or simple execution.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    struct(__MODULE__, opts)
  end

  @doc """
  Updates the context with output from a completed step.
  """
  @spec put_output(t(), String.t(), term()) :: t()
  def put_output(%__MODULE__{} = ctx, step_id, output) do
    %{ctx | step_outputs: Map.put(ctx.step_outputs, step_id, output)}
  end

  @doc """
  Gets the output of a previously completed step.
  """
  @spec get_output(t(), String.t()) :: term() | nil
  def get_output(%__MODULE__{step_outputs: outputs}, step_id) do
    Map.get(outputs, step_id)
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  defp extract_step_outputs(workflow) do
    graph = workflow.graph

    # Find all Facts with :produced edges from Steps
    graph
    |> Graph.vertices()
    |> Enum.filter(&match?(%Runic.Workflow.Fact{}, &1))
    |> Enum.reduce(%{}, fn fact, acc ->
      producing_step =
        graph
        |> Graph.in_neighbors(fact)
        |> Enum.find(&match?(%Runic.Workflow.Step{}, &1))

      case producing_step do
        %{name: name} when is_binary(name) ->
          # Step ID (name in Runic) is now the key-safe slug, use directly
          Map.put(acc, name, fact.value)

        _ ->
          acc
      end
    end)
  end
end
