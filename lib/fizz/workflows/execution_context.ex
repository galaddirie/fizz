defmodule Fizz.Workflows.ExecutionContext do
  @moduledoc """
  Typed workflow execution context.

  The struct has one canonical scope field, `:scope`. `to_legacy_map/1` and
  `put_legacy_aliases/1` keep the existing map contract intact while executors
  migrate incrementally.
  """

  alias Fizz.Accounts.Scope

  @type t :: %__MODULE__{
          input: term(),
          steps: map(),
          workflow: map(),
          env: map(),
          metadata: map(),
          scope: Scope.t() | nil,
          run_id: String.t() | nil,
          step_id: String.t() | nil,
          step_name: String.t() | nil,
          type_id: String.t() | nil,
          user_id: String.t() | nil,
          project_id: String.t() | nil,
          workos_organization_id: String.t() | nil,
          credential_resolver: function() | nil,
          trace: map(),
          opts: map()
        }

  defstruct [
    :input,
    :scope,
    :run_id,
    :step_id,
    :step_name,
    :type_id,
    :user_id,
    :project_id,
    :workos_organization_id,
    :credential_resolver,
    steps: %{},
    workflow: %{},
    env: %{},
    metadata: %{},
    trace: %{},
    opts: %{}
  ]

  @spec from_map(t() | map()) :: t()
  def from_map(%__MODULE__{} = context), do: context

  def from_map(map) when is_map(map) do
    existing = existing_context(map)
    metadata = map_value_or(map, :metadata, existing.metadata) |> map_or_empty()
    workflow = map_value_or(map, :workflow, existing.workflow) |> map_or_empty()

    %__MODULE__{
      input: map_value_or(map, :input, existing.input),
      steps: map_value_or(map, :steps, existing.steps) |> map_or_empty(),
      workflow: workflow,
      env: map_value_or(map, :env, existing.env) |> map_or_empty(),
      metadata: metadata,
      scope: canonical_scope(map, existing),
      run_id: first_value(map, existing, workflow, metadata, :run_id),
      step_id: map_value_or(map, :step_id, existing.step_id),
      step_name: map_value_or(map, :step_name, existing.step_name),
      type_id: map_value_or(map, :type_id, existing.type_id),
      user_id: first_value(map, existing, workflow, metadata, :user_id),
      project_id: first_value(map, existing, workflow, metadata, :project_id),
      workos_organization_id:
        first_value(map, existing, workflow, metadata, :workos_organization_id),
      credential_resolver: map_value_or(map, :_credential_resolver, existing.credential_resolver),
      trace: map_value_or(map, :trace, existing.trace) |> map_or_empty(),
      opts: map_value_or(map, :opts, existing.opts) |> map_or_empty()
    }
  end

  @spec to_legacy_map(t()) :: map()
  def to_legacy_map(%__MODULE__{} = context) do
    %{
      input: context.input,
      steps: context.steps,
      workflow: context.workflow,
      env: context.env,
      metadata: context.metadata,
      scope: context.scope,
      current_scope: context.scope,
      run_id: context.run_id,
      step_id: context.step_id,
      step_name: context.step_name,
      type_id: context.type_id,
      user_id: context.user_id,
      project_id: context.project_id,
      workos_organization_id: context.workos_organization_id,
      _credential_resolver: context.credential_resolver,
      execution_context: context
    }
  end

  @spec put_legacy_aliases(t() | map()) :: map()
  def put_legacy_aliases(%__MODULE__{} = context), do: to_legacy_map(context)

  def put_legacy_aliases(map) when is_map(map) do
    context = from_map(map)

    map
    |> Map.merge(to_legacy_map(context))
    |> Map.put(:execution_context, context)
  end

  defp existing_context(%{execution_context: %__MODULE__{} = context}), do: context
  defp existing_context(%{"execution_context" => %__MODULE__{} = context}), do: context
  defp existing_context(_map), do: %__MODULE__{}

  defp canonical_scope(map, existing) do
    metadata = map_value(map, :metadata) |> map_or_empty()

    case map_value(map, :scope) || map_value(map, :current_scope) || existing.scope do
      %Scope{} = scope -> scope
      _scope -> metadata_scope(metadata)
    end
  end

  defp metadata_scope(metadata) do
    case map_value(metadata, :scope) || map_value(metadata, :current_scope) do
      %Scope{} = scope -> scope
      _scope -> nil
    end
  end

  defp first_value(map, existing, workflow, metadata, key) do
    case fetch_map_value(map, key) do
      {:ok, nil} ->
        first_present([
          Map.get(existing, key),
          map_value(workflow, key),
          map_value(metadata, key)
        ])

      {:ok, value} ->
        value

      :error ->
        first_present([
          Map.get(existing, key),
          map_value(workflow, key),
          map_value(metadata, key)
        ])
    end
  end

  defp map_value(map, key) when is_map(map) and is_atom(key) do
    case fetch_map_value(map, key) do
      {:ok, value} -> value
      :error -> nil
    end
  end

  defp map_value(_map, _key), do: nil

  defp map_value_or(map, key, fallback) do
    case fetch_map_value(map, key) do
      {:ok, value} -> value
      :error -> fallback
    end
  end

  defp fetch_map_value(map, key) when is_map(map) and is_atom(key) do
    string_key = Atom.to_string(key)

    cond do
      Map.has_key?(map, key) -> {:ok, Map.get(map, key)}
      Map.has_key?(map, string_key) -> {:ok, Map.get(map, string_key)}
      true -> :error
    end
  end

  defp fetch_map_value(_map, _key), do: :error

  defp first_present(values), do: Enum.find(values, &(!is_nil(&1)))

  defp map_or_empty(map) when is_map(map), do: map
  defp map_or_empty(_value), do: %{}
end
