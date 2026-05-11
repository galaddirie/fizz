defmodule Fizz.Slots do
  @moduledoc """
  Context for per-user slot bindings.

  A slot is a typed declaration in a workflow step config that resolves to a
  concrete value per-user/per-run. Bindings persist a user's choice for a
  given workflow definition + step + slot key so future runs do not require
  reconfiguration.

  Public API for callers:

    * `list_for_user/3` — all bindings the user has set for a workflow
    * `get_binding/4` — fetch one binding by composite key
    * `upsert_binding/3` — validate, create, or update a binding
    * `delete_binding/4` — remove a binding
    * `bindings_for_run/1` — all bindings indexed for a run's actor + workflow
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Fizz.Accounts.Scope
  alias Fizz.Repo
  alias Fizz.Slots.Declaration
  alias Fizz.Slots.Registry
  alias Fizz.Workflows.{SlotBinding, WorkflowDefinitionVersion, WorkflowRun}

  @type descriptor :: %{
          step_id: String.t(),
          slot_key: String.t(),
          kind: String.t(),
          spec: map(),
          candidates: [map()]
        }

  @doc """
  Returns all slot bindings for a user against a workflow definition.
  """
  @spec list_for_user(String.t(), String.t(), String.t()) :: [SlotBinding.t()]
  def list_for_user(workos_organization_id, workflow_definition_id, user_id)
      when is_binary(workos_organization_id) and is_binary(workflow_definition_id) and
             is_binary(user_id) do
    from(b in SlotBinding,
      where:
        b.workos_organization_id == ^workos_organization_id and
          b.workflow_definition_id == ^workflow_definition_id and
          b.user_id == ^user_id
    )
    |> Repo.all()
  end

  def list_for_user(_workos_organization_id, _workflow_definition_id, _user_id), do: []

  @doc """
  Fetches a single binding by its composite key.
  """
  @spec get_binding(String.t(), String.t(), String.t(), String.t()) :: SlotBinding.t() | nil
  def get_binding(workflow_definition_id, user_id, step_id, slot_key)
      when is_binary(workflow_definition_id) and is_binary(user_id) and is_binary(step_id) and
             is_binary(slot_key) do
    Repo.get_by(SlotBinding,
      workflow_definition_id: workflow_definition_id,
      user_id: user_id,
      step_id: step_id,
      slot_key: slot_key
    )
  end

  @doc """
  Creates or updates a slot binding by its composite key after validating it
  against the workflow's slot declaration.

  Expects `attrs` to contain `user_id`, `workflow_definition_id`, `step_id`,
  `slot_key`, `kind`, `binding_data`, and `workos_organization_id`.
  """
  @spec upsert_binding(WorkflowDefinitionVersion.t(), Scope.t(), map()) ::
          {:ok, SlotBinding.t()} | {:error, Ecto.Changeset.t()}
  def upsert_binding(%WorkflowDefinitionVersion{} = version, %Scope{} = scope, attrs)
      when is_map(attrs) do
    attrs = atomize_keys(attrs)

    with {:ok, declaration} <- binding_declaration(version, attrs),
         :ok <- ensure_binding_context(version, scope, attrs),
         :ok <- ensure_binding_kind(declaration, attrs),
         :ok <-
           validate_binding_data(
             declaration.kind,
             Map.get(attrs, :binding_data) || %{},
             declaration.spec,
             scope
           ) do
      attrs
      |> Map.put(:kind, declaration.kind)
      |> do_upsert_binding()
    else
      {:error, {field, reason}} ->
        {:error, changeset_with_error(attrs, field, reason)}

      {:error, reason} ->
        {:error, changeset_with_error(attrs, :binding_data, reason)}
    end
  end

  def upsert_binding(_version, _scope, attrs) when is_map(attrs) do
    {:error,
     attrs
     |> atomize_keys()
     |> changeset_with_error(:workflow_definition_id, :slot_declaration_not_available)}
  end

  defp do_upsert_binding(attrs) when is_map(attrs) do
    existing =
      get_binding(
        Map.get(attrs, :workflow_definition_id),
        Map.get(attrs, :user_id),
        Map.get(attrs, :step_id),
        Map.get(attrs, :slot_key)
      )

    case existing do
      nil ->
        %SlotBinding{}
        |> SlotBinding.changeset(attrs)
        |> Repo.insert()

      %SlotBinding{} = binding ->
        binding
        |> SlotBinding.changeset(attrs)
        |> Repo.update()
    end
  end

  @doc """
  Returns normalized required slot declarations for the workflow version.
  """
  @spec required_slots(WorkflowDefinitionVersion.t() | [map()]) :: [map()]
  def required_slots(%WorkflowDefinitionVersion{} = version) do
    required_slots(version.steps || [])
  end

  def required_slots(steps) when is_list(steps) do
    Enum.flat_map(steps, &slot_declarations_for_step/1)
  end

  @doc """
  Checks whether `user_id` has bindings for all declared slots in a workflow.
  """
  @spec readiness(WorkflowDefinitionVersion.t(), String.t(), Scope.t()) ::
          :ready | {:needs_bindings, [descriptor()]}
  def readiness(%WorkflowDefinitionVersion{} = version, user_id, %Scope{} = scope)
      when is_binary(user_id) do
    workflow_definition_id = version.workflow_definition_id
    organization_id = scope.organization_id

    bindings =
      organization_id
      |> list_for_user(workflow_definition_id, user_id)
      |> index_bindings()

    descriptors =
      version
      |> required_slots()
      |> Enum.flat_map(fn declaration ->
        case binding_status(declaration, bindings, scope) do
          :ok ->
            []

          {:error, reason} ->
            [
              declaration
              |> attach_candidates(scope)
              |> Map.put(:reason, reason)
            ]
        end
      end)

    case descriptors do
      [] -> :ready
      _ -> {:needs_bindings, descriptors}
    end
  end

  def readiness(%WorkflowDefinitionVersion{} = version, _user_id, _scope) do
    case required_slots(version) do
      [] -> :ready
      slots -> {:needs_bindings, Enum.map(slots, &Map.put(&1, :candidates, []))}
    end
  end

  @doc """
  Builds a runtime slot resolver for a run-like map or struct.
  """
  @spec runtime_resolver(Scope.t(), WorkflowRun.t() | map()) ::
          {:ok, function()} | {:error, term()}
  def runtime_resolver(%Scope{} = scope, run_or_attrs) when is_map(run_or_attrs) do
    with {:ok, user_id} <- user_id_for_run(run_or_attrs, scope),
         {:ok, workflow_definition_id} <- workflow_definition_id(run_or_attrs),
         {:ok, organization_id} <- organization_id(run_or_attrs) do
      bindings =
        organization_id
        |> list_for_user(workflow_definition_id, user_id)
        |> index_bindings()

      {:ok, resolver_for_bindings(bindings, scope)}
    end
  end

  def runtime_resolver(_scope, _run_or_attrs), do: {:error, :scope_not_available}

  @doc """
  Builds a runtime slot resolver from a preloaded binding index.
  """
  @spec resolver_for_bindings(%{optional({String.t(), String.t()}) => SlotBinding.t()}, Scope.t()) ::
          function()
  def resolver_for_bindings(bindings, %Scope{} = scope) when is_map(bindings) do
    fn kind, slot_key, step_id, spec ->
      resolve_bound_slot(bindings, scope, kind, slot_key, step_id, spec)
    end
  end

  @doc """
  Validates kind-specific binding data with spec-aware callbacks when available.
  """
  @spec validate_binding_data(String.t(), map(), map()) :: :ok | {:error, term()}
  def validate_binding_data(kind, binding_data, spec)
      when is_binary(kind) and is_map(binding_data) and is_map(spec) do
    case Registry.fetch(kind) do
      {:ok, module} ->
        cond do
          function_exported?(module, :validate_binding_data, 2) ->
            module.validate_binding_data(binding_data, spec)

          function_exported?(module, :validate_binding_data, 1) ->
            module.validate_binding_data(binding_data)

          true ->
            :ok
        end

      :error ->
        {:error, :unknown_slot_kind}
    end
  end

  def validate_binding_data(_kind, _binding_data, _spec), do: {:error, :invalid_binding_data}

  @doc """
  Validates kind-specific binding data against a declaration spec and user scope.
  """
  @spec validate_binding_data(String.t(), map(), map(), Scope.t()) :: :ok | {:error, term()}
  def validate_binding_data(kind, binding_data, spec, %Scope{} = scope)
      when is_binary(kind) and is_map(binding_data) and is_map(spec) do
    case Registry.fetch(kind) do
      {:ok, module} ->
        cond do
          function_exported?(module, :validate_binding_data, 3) ->
            module.validate_binding_data(binding_data, spec, scope)

          function_exported?(module, :validate_binding_data, 2) ->
            module.validate_binding_data(binding_data, spec)

          function_exported?(module, :validate_binding_data, 1) ->
            module.validate_binding_data(binding_data)

          true ->
            :ok
        end

      :error ->
        {:error, :unknown_slot_kind}
    end
  end

  def validate_binding_data(_kind, _binding_data, _spec, _scope),
    do: {:error, :invalid_binding_data}

  @doc """
  Returns options for a slot declaration or normalized kind/spec pair.
  """
  @spec candidate_options(String.t(), map(), Scope.t()) :: {:ok, [map()]} | {:error, term()}
  def candidate_options(kind, spec, %Scope{} = scope) when is_binary(kind) and is_map(spec) do
    case Registry.fetch(kind) do
      {:ok, module} -> module.candidate_options(spec, scope)
      :error -> {:error, :unknown_slot_kind}
    end
  end

  def candidate_options(_kind, _spec, _scope), do: {:error, :invalid_scope}

  @doc """
  Deletes a binding by composite key. Returns `:ok` even if it didn't exist.
  """
  @spec delete_binding(String.t(), String.t(), String.t(), String.t()) :: :ok
  def delete_binding(workflow_definition_id, user_id, step_id, slot_key) do
    case get_binding(workflow_definition_id, user_id, step_id, slot_key) do
      nil ->
        :ok

      %SlotBinding{} = binding ->
        case Repo.delete(binding) do
          {:ok, _binding} -> :ok
          {:error, _changeset} -> :ok
        end
    end
  end

  @doc """
  Returns all bindings for the run's actor against the run's workflow,
  indexed by `{step_id, slot_key}` for fast lookup at runtime.
  """
  @spec bindings_for_run(WorkflowRun.t()) :: %{
          optional({String.t(), String.t()}) => SlotBinding.t()
        }
  def bindings_for_run(%WorkflowRun{} = run) do
    user_id = Map.get(run, :user_id)
    workflow_definition_id = run.workflow_definition_id
    workos_organization_id = run.workos_organization_id

    if is_binary(user_id) and is_binary(workflow_definition_id) and
         is_binary(workos_organization_id) do
      workos_organization_id
      |> list_for_user(workflow_definition_id, user_id)
      |> Map.new(fn binding -> {{binding.step_id, binding.slot_key}, binding} end)
    else
      %{}
    end
  end

  def bindings_for_run(_run), do: %{}

  defp binding_declaration(%WorkflowDefinitionVersion{} = version, attrs) when is_map(attrs) do
    step_id = Map.get(attrs, :step_id)
    slot_key = Map.get(attrs, :slot_key)

    case Enum.find(required_slots(version), &(&1.step_id == step_id and &1.slot_key == slot_key)) do
      nil -> {:error, {:slot_key, :slot_declaration_not_found}}
      declaration -> {:ok, declaration}
    end
  end

  defp ensure_binding_context(%WorkflowDefinitionVersion{} = version, %Scope{} = scope, attrs) do
    with :ok <-
           ensure_attr(
             attrs,
             :workflow_definition_id,
             version.workflow_definition_id,
             :workflow_definition_mismatch
           ),
         {:ok, organization_id} <- scope_organization_id(scope),
         :ok <-
           ensure_attr(
             attrs,
             :workos_organization_id,
             organization_id,
             :organization_mismatch
           ),
         {:ok, user_id} <- scope_user_id(scope),
         :ok <- ensure_attr(attrs, :user_id, user_id, :user_mismatch) do
      :ok
    end
  end

  defp ensure_attr(attrs, field, expected, reason) when is_binary(expected) do
    case Map.get(attrs, field) do
      ^expected -> :ok
      _ -> {:error, {field, reason}}
    end
  end

  defp ensure_attr(_attrs, field, _expected, reason), do: {:error, {field, reason}}

  defp scope_organization_id(%Scope{organization_id: organization_id})
       when is_binary(organization_id) and organization_id != "",
       do: {:ok, organization_id}

  defp scope_organization_id(_scope),
    do: {:error, {:workos_organization_id, :organization_required}}

  defp scope_user_id(%Scope{user: %{id: user_id}}) when is_binary(user_id) and user_id != "",
    do: {:ok, user_id}

  defp scope_user_id(_scope), do: {:error, {:user_id, :user_required}}

  defp changeset_with_error(attrs, field, reason) do
    %SlotBinding{}
    |> SlotBinding.changeset(attrs)
    |> Changeset.add_error(field, format_reason(reason))
  end

  defp binding_status(
         %{step_id: step_id, slot_key: slot_key, kind: kind, spec: spec},
         bindings,
         %Scope{} = scope
       ) do
    with {:ok, binding} <- fetch_binding(bindings, step_id, slot_key),
         :ok <- ensure_binding_kind(binding, kind),
         binding_data <- binding_data_for_resolution(binding),
         :ok <- validate_binding_data(kind, binding_data, spec, scope) do
      :ok
    end
  end

  defp slot_declarations_for_step(step) when is_map(step) do
    step_id = fetch_value(step, :id)
    config = fetch_value(step, :config) || %{}

    if is_binary(step_id) do
      config
      |> Declaration.walk()
      |> Enum.flat_map(fn %{path: path, declaration: declaration} ->
        case Declaration.normalize(declaration) do
          {:ok, normalized} ->
            [
              normalized
              |> Map.put(:step_id, step_id)
              |> Map.put(:field, Declaration.format_path(path))
            ]

          {:error, _reason} ->
            []
        end
      end)
    else
      []
    end
  end

  defp slot_declarations_for_step(_step), do: []

  defp attach_candidates(%{kind: kind, spec: spec} = descriptor, %Scope{} = scope) do
    candidates =
      case candidate_options(kind, spec, scope) do
        {:ok, options} -> options
        {:error, _reason} -> []
      end

    Map.put(descriptor, :candidates, candidates)
  end

  defp index_bindings(bindings) when is_list(bindings) do
    Map.new(bindings, fn binding -> {{binding.step_id, binding.slot_key}, binding} end)
  end

  defp resolve_bound_slot(bindings, %Scope{} = scope, kind, slot_key, step_id, spec) do
    with {:ok, module} <- Registry.fetch(kind),
         {:ok, binding} <- fetch_binding(bindings, step_id, slot_key),
         :ok <- ensure_binding_kind(binding, kind),
         binding_data <- binding_data_for_resolution(binding),
         :ok <- validate_binding_data(kind, binding_data, spec),
         {:ok, value} <- module.resolve(spec, binding_data, scope) do
      {:ok, value}
    end
  end

  defp fetch_binding(bindings, step_id, slot_key) do
    case Map.get(bindings, {step_id, slot_key}) do
      %SlotBinding{} = binding -> {:ok, binding}
      _ -> {:error, :slot_unbound}
    end
  end

  defp ensure_binding_kind(%{kind: expected_kind}, attrs) when is_map(attrs) do
    case Map.get(attrs, :kind) do
      ^expected_kind -> :ok
      _ -> {:error, {:kind, :slot_kind_mismatch}}
    end
  end

  defp ensure_binding_kind(%SlotBinding{kind: kind}, kind), do: :ok
  defp ensure_binding_kind(%SlotBinding{}, _kind), do: {:error, :slot_kind_mismatch}

  defp binding_data_for_resolution(%SlotBinding{} = binding) do
    binding.binding_data
    |> ensure_map()
    |> Map.put_new("owner_user_id", binding.user_id)
  end

  defp ensure_map(value) when is_map(value), do: value
  defp ensure_map(_value), do: %{}

  defp user_id_for_run(run_or_attrs, scope) when is_map(run_or_attrs) do
    case fetch_value(run_or_attrs, :user_id) do
      user_id when is_binary(user_id) and user_id != "" ->
        {:ok, user_id}

      _ ->
        case scope do
          %Scope{user: %{id: user_id}} when is_binary(user_id) -> {:ok, user_id}
          _ -> {:error, :user_id_required}
        end
    end
  end

  defp workflow_definition_id(run_or_attrs) do
    case fetch_value(run_or_attrs, :workflow_definition_id) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, :workflow_definition_id_required}
    end
  end

  defp organization_id(run_or_attrs) do
    case fetch_value(run_or_attrs, :workos_organization_id) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, :organization_id_required}
    end
  end

  defp fetch_value(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp fetch_value(_map, _key), do: nil

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)

  defp atomize_keys(attrs) do
    Map.new(attrs, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  rescue
    ArgumentError -> attrs
  end
end
