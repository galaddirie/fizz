defmodule Fizz.Credentials do
  @moduledoc """
  Context for per-user credential bindings.

  Credential requirements are declared by step config fields and resolved at
  run time to a user-owned credential reference. This module owns persistence,
  readiness, auto-binding, and runtime resolution for those requirements.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Fizz.Accounts.Scope
  alias Fizz.Credentials.{Declaration, Options}
  alias Fizz.Repo
  alias Fizz.Workflows.{CredentialBinding, WorkflowDefinitionVersion, WorkflowRun}

  @type descriptor :: %{
          step_id: String.t(),
          requirement_key: String.t(),
          provider: String.t(),
          auth_type: String.t(),
          field: String.t() | nil,
          candidates: [map()],
          reason: term()
        }

  @doc """
  Returns all credential bindings for a user against a workflow definition.
  """
  @spec list_for_user(String.t(), String.t(), String.t()) :: [CredentialBinding.t()]
  def list_for_user(workos_organization_id, workflow_definition_id, user_id)
      when is_binary(workos_organization_id) and is_binary(workflow_definition_id) and
             is_binary(user_id) do
    from(b in CredentialBinding,
      where:
        b.workos_organization_id == ^workos_organization_id and
          b.workflow_definition_id == ^workflow_definition_id and
          b.user_id == ^user_id
    )
    |> Repo.all()
  end

  def list_for_user(_workos_organization_id, _workflow_definition_id, _user_id), do: []

  @doc """
  Fetches a single binding by workflow, user, step, and requirement key.
  """
  @spec get_binding(String.t(), String.t(), String.t(), String.t()) :: CredentialBinding.t() | nil
  def get_binding(workflow_definition_id, user_id, step_id, requirement_key)
      when is_binary(workflow_definition_id) and is_binary(user_id) and is_binary(step_id) and
             is_binary(requirement_key) do
    Repo.get_by(CredentialBinding,
      workflow_definition_id: workflow_definition_id,
      user_id: user_id,
      step_id: step_id,
      requirement_key: requirement_key
    )
  end

  @doc """
  Creates or updates a credential binding after validating it against the
  workflow's declared credential requirement.
  """
  @spec upsert_binding(WorkflowDefinitionVersion.t(), Scope.t(), map()) ::
          {:ok, CredentialBinding.t()} | {:error, Ecto.Changeset.t()}
  def upsert_binding(%WorkflowDefinitionVersion{} = version, %Scope{} = scope, attrs)
      when is_map(attrs) do
    attrs = atomize_keys(attrs)

    with {:ok, requirement} <- binding_requirement(version, attrs),
         :ok <- ensure_binding_context(version, scope, attrs),
         binding_data <- Map.get(attrs, :binding_data) || %{},
         :ok <- Options.validate_binding_data(binding_data, requirement, scope) do
      do_upsert_binding(attrs)
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
     |> changeset_with_error(:workflow_definition_id, :credential_requirement_not_available)}
  end

  defp do_upsert_binding(attrs) when is_map(attrs) do
    existing =
      get_binding(
        Map.get(attrs, :workflow_definition_id),
        Map.get(attrs, :user_id),
        Map.get(attrs, :step_id),
        Map.get(attrs, :requirement_key)
      )

    case existing do
      nil ->
        %CredentialBinding{}
        |> CredentialBinding.changeset(attrs)
        |> Repo.insert()

      %CredentialBinding{} = binding ->
        binding
        |> CredentialBinding.changeset(attrs)
        |> Repo.update()
    end
  end

  @doc """
  Returns normalized required credential declarations for the workflow version.
  """
  @spec required_credentials(WorkflowDefinitionVersion.t() | [map()]) :: [map()]
  def required_credentials(%WorkflowDefinitionVersion{} = version) do
    required_credentials(version.steps || [])
  end

  def required_credentials(steps) when is_list(steps) do
    Enum.flat_map(steps, &credential_declarations_for_step/1)
  end

  @doc """
  Checks whether `user_id` has usable bindings for every credential requirement.
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
      |> required_credentials()
      |> Enum.flat_map(fn requirement ->
        case binding_status(requirement, bindings, scope) do
          :ok ->
            []

          {:error, reason} ->
            [
              requirement
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
    case required_credentials(version) do
      [] -> :ready
      requirements -> {:needs_bindings, Enum.map(requirements, &Map.put(&1, :candidates, []))}
    end
  end

  @doc """
  Best-effort auto-binding for OAuth credentials with exactly one safe choice.
  """
  @spec ensure_auto_bindings(WorkflowDefinitionVersion.t(), String.t(), Scope.t()) ::
          {:ok, [CredentialBinding.t()]} | {:error, Ecto.Changeset.t()}
  def ensure_auto_bindings(%WorkflowDefinitionVersion{} = version, user_id, %Scope{} = scope)
      when is_binary(user_id) do
    workflow_definition_id = version.workflow_definition_id

    with {:ok, organization_id} <- scope_organization_id(scope) do
      bindings =
        organization_id
        |> list_for_user(workflow_definition_id, user_id)
        |> index_bindings()

      result =
        version
        |> required_credentials()
        |> Enum.reduce_while({:ok, []}, fn requirement, {:ok, auto_bound} ->
          case auto_bind_requirement(
                 version,
                 scope,
                 user_id,
                 organization_id,
                 bindings,
                 requirement
               ) do
            {:ok, nil} -> {:cont, {:ok, auto_bound}}
            {:ok, %CredentialBinding{} = binding} -> {:cont, {:ok, [binding | auto_bound]}}
            {:error, _changeset} = error -> {:halt, error}
          end
        end)

      case result do
        {:ok, auto_bound} -> {:ok, Enum.reverse(auto_bound)}
        {:error, _changeset} = error -> error
      end
    else
      {:error, _reason} -> {:ok, []}
    end
  end

  def ensure_auto_bindings(_version, _user_id, _scope), do: {:ok, []}

  @doc """
  Builds a runtime credential resolver for a run-like map or struct.
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
  Builds a runtime credential resolver from a preloaded binding index.
  """
  @spec resolver_for_bindings(
          %{optional({String.t(), String.t()}) => CredentialBinding.t()},
          Scope.t()
        ) ::
          function()
  def resolver_for_bindings(bindings, %Scope{} = scope) when is_map(bindings) do
    fn requirement_key, step_id, provider, auth_type ->
      requirement = %{
        requirement_key: requirement_key,
        provider: provider,
        auth_type: auth_type
      }

      resolve_bound_credential(bindings, scope, step_id, requirement)
    end
  end

  @doc """
  Returns credential options for a requirement.
  """
  @spec candidate_options(map(), Scope.t()) :: {:ok, [map()]} | {:error, term()}
  def candidate_options(requirement, %Scope{} = scope) when is_map(requirement) do
    Options.candidate_options(requirement, scope)
  end

  def candidate_options(_requirement, _scope), do: {:error, :invalid_scope}

  @doc """
  Deletes a binding by composite key. Returns `:ok` even if it didn't exist.
  """
  @spec delete_binding(String.t(), String.t(), String.t(), String.t()) :: :ok
  def delete_binding(workflow_definition_id, user_id, step_id, requirement_key) do
    case get_binding(workflow_definition_id, user_id, step_id, requirement_key) do
      nil ->
        :ok

      %CredentialBinding{} = binding ->
        case Repo.delete(binding) do
          {:ok, _binding} -> :ok
          {:error, _changeset} -> :ok
        end
    end
  end

  @doc """
  Returns all bindings for the run's actor, indexed by `{step_id, requirement_key}`.
  """
  @spec bindings_for_run(WorkflowRun.t()) :: %{
          optional({String.t(), String.t()}) => CredentialBinding.t()
        }
  def bindings_for_run(%WorkflowRun{} = run) do
    user_id = Map.get(run, :user_id)
    workflow_definition_id = run.workflow_definition_id
    workos_organization_id = run.workos_organization_id

    if is_binary(user_id) and is_binary(workflow_definition_id) and
         is_binary(workos_organization_id) do
      workos_organization_id
      |> list_for_user(workflow_definition_id, user_id)
      |> index_bindings()
    else
      %{}
    end
  end

  def bindings_for_run(_run), do: %{}

  defp binding_requirement(%WorkflowDefinitionVersion{} = version, attrs) when is_map(attrs) do
    step_id = Map.get(attrs, :step_id)
    requirement_key = Map.get(attrs, :requirement_key)

    case Enum.find(
           required_credentials(version),
           &(&1.step_id == step_id and &1.requirement_key == requirement_key)
         ) do
      nil -> {:error, {:requirement_key, :credential_requirement_not_found}}
      requirement -> {:ok, requirement}
    end
  end

  defp auto_bind_requirement(
         %WorkflowDefinitionVersion{} = version,
         %Scope{} = scope,
         user_id,
         organization_id,
         bindings,
         %{step_id: step_id, requirement_key: requirement_key} = requirement
       ) do
    binding_key = {step_id, requirement_key}

    cond do
      Map.has_key?(bindings, binding_key) ->
        {:ok, nil}

      not auto_bindable_requirement?(requirement) ->
        {:ok, nil}

      true ->
        maybe_upsert_auto_binding(version, scope, user_id, organization_id, requirement)
    end
  end

  defp auto_bind_requirement(
         _version,
         _scope,
         _user_id,
         _organization_id,
         _bindings,
         _requirement
       ),
       do: {:ok, nil}

  defp maybe_upsert_auto_binding(version, scope, user_id, organization_id, requirement) do
    with {:ok, [candidate]} <- candidate_options_for_auto_binding(requirement, scope),
         {:ok, credential_id} <- candidate_id(candidate) do
      upsert_binding(version, scope, %{
        user_id: user_id,
        workflow_definition_id: version.workflow_definition_id,
        step_id: requirement.step_id,
        requirement_key: requirement.requirement_key,
        binding_data: %{"credential_id" => credential_id},
        workos_organization_id: organization_id
      })
    else
      :skip -> {:ok, nil}
      {:error, :no_auto_binding_candidate} -> {:ok, nil}
      {:error, :invalid_candidate} -> {:ok, nil}
      {:error, _reason} -> {:ok, nil}
    end
  end

  defp candidate_options_for_auto_binding(requirement, scope) when is_map(requirement) do
    case candidate_options(requirement, scope) do
      {:ok, [_candidate] = candidates} -> {:ok, candidates}
      {:ok, _candidates} -> :skip
      {:error, _reason} -> :skip
    end
  end

  defp candidate_options_for_auto_binding(_requirement, _scope), do: :skip

  defp auto_bindable_requirement?(%{auth_type: "oauth"}), do: true
  defp auto_bindable_requirement?(_requirement), do: false

  defp candidate_id(candidate) when is_map(candidate) do
    case fetch_value(candidate, :id) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _ -> {:error, :invalid_candidate}
    end
  end

  defp candidate_id(_candidate), do: {:error, :invalid_candidate}

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
    %CredentialBinding{}
    |> CredentialBinding.changeset(attrs)
    |> Changeset.add_error(field, format_reason(reason))
  end

  defp binding_status(requirement, bindings, %Scope{} = scope) do
    with {:ok, binding} <-
           fetch_binding(bindings, requirement.step_id, requirement.requirement_key),
         binding_data <- binding_data_for_resolution(binding),
         :ok <- Options.validate_binding_data(binding_data, requirement, scope) do
      :ok
    end
  end

  defp credential_declarations_for_step(step) when is_map(step) do
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

  defp credential_declarations_for_step(_step), do: []

  defp attach_candidates(requirement, %Scope{} = scope) do
    candidates =
      case candidate_options(requirement, scope) do
        {:ok, options} -> options
        {:error, _reason} -> []
      end

    Map.put(requirement, :candidates, candidates)
  end

  defp index_bindings(bindings) when is_list(bindings) do
    Map.new(bindings, fn binding -> {{binding.step_id, binding.requirement_key}, binding} end)
  end

  defp resolve_bound_credential(bindings, %Scope{} = scope, step_id, requirement) do
    with {:ok, binding} <- fetch_binding(bindings, step_id, requirement.requirement_key),
         binding_data <- binding_data_for_resolution(binding),
         :ok <- Options.validate_binding_data(binding_data, requirement),
         {:ok, value} <- Options.resolve(requirement, binding_data, scope) do
      {:ok, value}
    end
  end

  defp fetch_binding(bindings, step_id, requirement_key) do
    case Map.get(bindings, {step_id, requirement_key}) do
      %CredentialBinding{} = binding -> {:ok, binding}
      _ -> {:error, :credential_unbound}
    end
  end

  defp binding_data_for_resolution(%CredentialBinding{} = binding) do
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
