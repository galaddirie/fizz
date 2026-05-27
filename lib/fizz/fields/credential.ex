defmodule Fizz.Fields.Credential do
  @moduledoc """
  Credential field handler.

  Credentials are a field type at declaration time. Provider/auth runtime logic
  stays with integrations and accounts, while this module owns the field
  handler concerns: declaration maps, editor options, readiness, auto-binding,
  runtime binding resolution, and provider credential form fields.
  """

  import Ecto.Query

  alias Ecto.Changeset
  alias Fizz.Accounts.{ExternalAuth, Scope}
  alias Fizz.Fields
  alias Fizz.Fields.Definition
  alias Fizz.Integrations.ProviderCatalog
  alias Fizz.Repo
  alias Fizz.Workflows.{CredentialBinding, WorkflowDefinitionVersion, WorkflowRun}

  @max_options 50

  @type descriptor :: %{
          step_id: String.t(),
          requirement_key: String.t(),
          provider: String.t(),
          auth_type: String.t(),
          field: String.t() | nil,
          candidates: [map()],
          reason: term()
        }

  @type field :: %{
          key: String.t(),
          label: String.t(),
          input_type: String.t(),
          placeholder: String.t() | nil,
          autocomplete: String.t() | nil,
          required: boolean(),
          secret?: boolean(),
          order: integer()
        }

  @type path :: [String.t()]
  @type normalized :: %{
          requirement_key: String.t(),
          provider: String.t(),
          auth_type: String.t()
        }

  @type walked :: %{
          path: path(),
          declaration: map()
        }

  @doc """
  Resolves credential options for workflow step config fields.
  """
  @spec resolve(map()) :: {:ok, [map()]} | {:error, term()}
  def resolve(%{q: query, params: params, context: context}) do
    with {:ok, scope} <- fetch_scope(context),
         {:ok, options} <-
           options_for_requirement(
             requirement_from_params(params),
             scope,
             q: query,
             limit: @max_options
           ) do
      {:ok, options}
    end
  end

  def resolve(_request), do: {:error, :invalid_resolver_request}

  @doc """
  Returns true when `value` is a credential declaration map.
  """
  @spec declaration?(term()) :: boolean()
  def declaration?(value) when is_map(value) do
    Map.get(value, "$credential") == true or Map.get(value, :"$credential") == true
  end

  def declaration?(_value), do: false

  @doc """
  Walks a nested term and returns every credential declaration with its field path.
  """
  @spec walk(term()) :: [walked()]
  def walk(value), do: do_walk(value, [])

  @doc """
  Normalizes a credential declaration to string keys needed by compiler/runtime code.
  """
  @spec normalize(term()) :: {:ok, normalized()} | {:error, term()}
  def normalize(value) when is_map(value) do
    with true <- declaration?(value),
         {:ok, requirement_key} <- required_string(value, "requirement_key"),
         {:ok, provider} <- required_string(value, "provider"),
         {:ok, auth_type} <- required_string(value, "auth_type"),
         :ok <- validate_auth_type(auth_type) do
      {:ok, %{requirement_key: requirement_key, provider: provider, auth_type: auth_type}}
    else
      false -> {:error, :not_a_credential_declaration}
      {:error, _reason} = error -> error
    end
  end

  def normalize(_value), do: {:error, :not_a_credential_declaration}

  @doc """
  Validates a credential declaration.
  """
  @spec validate(term()) :: :ok | {:error, String.t()}
  def validate(value) do
    with {:ok, _declaration} <- normalize(value) do
      :ok
    else
      {:error, {:missing_field, field}} ->
        {:error, "credential is missing #{field}"}

      {:error, :not_a_credential_declaration} ->
        {:error, "credential declaration is invalid"}

      {:error, :invalid_auth_type} ->
        {:error, "credential auth_type must be api_key or oauth"}

      {:error, reason} when is_binary(reason) ->
        {:error, reason}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  @doc """
  Formats a declaration path for issue reporting.
  """
  @spec format_path(path()) :: String.t() | nil
  def format_path([]), do: nil
  def format_path(path), do: Enum.join(path, ".")

  @doc """
  Returns provider credential-creation fields in the settings form shape.
  """
  @spec fields(String.t()) :: [field()]
  def fields(provider_id) when is_binary(provider_id) do
    provider_id
    |> field_definitions()
    |> Enum.map(&form_field/1)
    |> Enum.sort_by(&{&1.order, &1.key})
  end

  def fields(_provider_id), do: []

  @doc """
  Returns default credential form values for a provider.
  """
  @spec defaults(String.t()) :: map()
  def defaults(provider_id) when is_binary(provider_id) do
    provider_id
    |> field_definitions()
    |> Fields.defaults()
  end

  def defaults(_provider_id), do: %{}

  @doc """
  Extracts the transient secret value from credential create/rotate params.
  """
  @spec secret_value(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def secret_value(provider_id, attrs) when is_binary(provider_id) and is_map(attrs) do
    case secret_fields(provider_id) do
      [] ->
        legacy_secret_value(attrs)

      [field] ->
        attrs
        |> credential_value(field.key)
        |> normalize_secret_value()

      fields ->
        credential_values = credential_values(attrs)

        with :ok <- validate_secret_fields(fields, credential_values) do
          {:ok, Jason.encode!(Map.take(credential_values, Enum.map(fields, & &1.key)))}
        end
    end
  end

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
         :ok <- validate_binding_data(binding_data, requirement, scope) do
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
    options_for_requirement(requirement, scope)
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
         :ok <- validate_binding_data(binding_data, requirement, scope) do
      :ok
    end
  end

  defp credential_declarations_for_step(step) when is_map(step) do
    step_id = fetch_value(step, :id)
    config = fetch_value(step, :config) || %{}

    if is_binary(step_id) do
      config
      |> walk()
      |> Enum.flat_map(fn %{path: path, declaration: declaration} ->
        case normalize(declaration) do
          {:ok, normalized} ->
            [
              normalized
              |> Map.put(:step_id, step_id)
              |> Map.put(:field, format_path(path))
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
         :ok <- validate_binding_data(binding_data, requirement),
         {:ok, value} <- resolve_binding_value(requirement, binding_data, scope) do
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

  defp field_definitions(provider_id) when is_binary(provider_id) do
    case ProviderCatalog.provider(provider_id) do
      {:ok, provider} ->
        provider
        |> Map.get(:credential_fields, default_provider_fields(provider))
        |> Fields.validate!()

      {:error, _reason} ->
        []
    end
  end

  defp default_provider_fields(%{type: :api_key} = provider) do
    [
      Fields.password("secret",
        label: "#{provider.label} API key",
        required?: true,
        default: "",
        autocomplete: "new-password",
        placeholder: api_key_placeholder(provider.id),
        order: 10
      )
    ]
  end

  defp default_provider_fields(%{type: :oauth}), do: []
  defp default_provider_fields(_provider), do: []

  defp form_field(%Definition{} = field) do
    %{
      key: field.key,
      label: field.label || Phoenix.Naming.humanize(field.key),
      input_type: input_type(field),
      placeholder: field.placeholder,
      autocomplete: field.autocomplete,
      required: field.required?,
      secret?: field.secret? or field.write_only?,
      order: field.order
    }
  end

  defp input_type(%Definition{component: "password"}), do: "password"
  defp input_type(%Definition{type: :password}), do: "password"
  defp input_type(%Definition{type: :number}), do: "number"
  defp input_type(%Definition{type: :boolean}), do: "checkbox"
  defp input_type(_field), do: "text"

  defp secret_fields(provider_id), do: Enum.filter(fields(provider_id), & &1.secret?)

  defp credential_value(attrs, key) do
    attrs
    |> credential_values()
    |> Map.get(key)
    |> case do
      nil -> direct_credential_value(attrs, key)
      value -> value
    end
  end

  defp direct_credential_value(attrs, "secret"),
    do:
      Map.get(attrs, "secret") || Map.get(attrs, :secret) || Map.get(attrs, "value") ||
        Map.get(attrs, :value)

  defp direct_credential_value(attrs, "value"),
    do:
      Map.get(attrs, "value") || Map.get(attrs, :value) || Map.get(attrs, "secret") ||
        Map.get(attrs, :secret)

  defp direct_credential_value(attrs, key), do: Map.get(attrs, key)

  defp credential_values(attrs) do
    case Map.get(attrs, :credentials) || Map.get(attrs, "credentials") do
      values when is_map(values) -> values
      _values -> %{}
    end
  end

  defp validate_secret_fields(fields, credential_values) do
    missing? =
      Enum.any?(fields, fn field ->
        field.required and
          not match?({:ok, _value}, normalize_secret_value(Map.get(credential_values, field.key)))
      end)

    if missing?, do: {:error, :missing_secret_value}, else: :ok
  end

  defp legacy_secret_value(attrs) do
    attrs
    |> Map.get(:secret, Map.get(attrs, "secret", Map.get(attrs, :value, Map.get(attrs, "value"))))
    |> normalize_secret_value()
  end

  defp normalize_secret_value(secret) when is_binary(secret) do
    trimmed_secret = String.trim(secret)

    if byte_size(trimmed_secret) > 0 do
      {:ok, trimmed_secret}
    else
      {:error, :missing_secret_value}
    end
  end

  defp normalize_secret_value(_secret), do: {:error, :missing_secret_value}

  defp fetch_scope(context) when is_map(context) do
    case fetch_value(context, :current_scope) do
      %Scope{} = scope -> {:ok, scope}
      _ -> {:error, :scope_not_available}
    end
  end

  defp fetch_scope(_context), do: {:error, :scope_not_available}

  defp requirement_from_params(params) do
    params = normalize_params(params)

    %{}
    |> maybe_put("provider", list_param(params, :provider_filter))
    |> maybe_put("auth_type", list_param(params, :auth_types))
  end

  defp normalize_params(params) when is_map(params), do: params
  defp normalize_params(_params), do: %{}

  defp do_walk(value, path) when is_map(value) do
    if declaration?(value) do
      [%{path: path, declaration: value}]
    else
      Enum.flat_map(value, fn {key, nested_value} ->
        do_walk(nested_value, path ++ [to_string(key)])
      end)
    end
  end

  defp do_walk(values, path) when is_list(values) do
    values
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} ->
      do_walk(value, path ++ [Integer.to_string(index)])
    end)
  end

  defp do_walk(_value, _path), do: []

  defp required_string(map, key) do
    case fetch_value(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:missing_field, key}}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, {:missing_field, key}}
    end
  end

  defp validate_auth_type(auth_type) when auth_type in ["api_key", "oauth"], do: :ok
  defp validate_auth_type(_auth_type), do: {:error, :invalid_auth_type}

  defp resolve_binding_value(requirement, binding_data, %Scope{user: %{id: user_id}})
       when is_map(requirement) and is_map(binding_data) and is_binary(user_id) do
    with {:ok, provider} <- fetch_string(requirement, "provider"),
         {:ok, auth_type} <- fetch_string(requirement, "auth_type"),
         {:ok, credential_id} <- fetch_string(binding_data, "credential_id") do
      {:ok,
       %{
         "id" => credential_id,
         "provider" => provider,
         "auth_type" => auth_type,
         "owner_user_id" => user_id
       }}
    end
  end

  defp resolve_binding_value(requirement, binding_data, %Scope{})
       when is_map(requirement) and is_map(binding_data) do
    with {:ok, owner_user_id} <- fetch_string(binding_data, "owner_user_id"),
         {:ok, provider} <- fetch_string(requirement, "provider"),
         {:ok, auth_type} <- fetch_string(requirement, "auth_type"),
         {:ok, credential_id} <- fetch_string(binding_data, "credential_id") do
      {:ok,
       %{
         "id" => credential_id,
         "provider" => provider,
         "auth_type" => auth_type,
         "owner_user_id" => owner_user_id
       }}
    end
  end

  defp resolve_binding_value(_requirement, _binding_data, _scope),
    do: {:error, :invalid_credential_resolution_args}

  defp validate_requirement(requirement) when is_map(requirement) do
    with {:ok, _provider} <- fetch_string(requirement, "provider"),
         {:ok, auth_type} <- fetch_string(requirement, "auth_type"),
         true <- auth_type in ["api_key", "oauth"] do
      :ok
    else
      false -> {:error, :invalid_auth_type}
      {:error, _reason} = error -> error
    end
  end

  defp validate_requirement(_requirement), do: {:error, :invalid_requirement}

  defp validate_binding_data(%{"credential_id" => credential_id})
       when is_binary(credential_id) do
    case String.trim(credential_id) do
      "" -> {:error, :credential_id_required}
      _ -> :ok
    end
  end

  defp validate_binding_data(_binding_data), do: {:error, :credential_id_required}

  defp validate_binding_data(binding_data, requirement)
       when is_map(binding_data) and is_map(requirement) do
    with :ok <- validate_requirement(requirement),
         :ok <- validate_binding_data(binding_data) do
      :ok
    end
  end

  defp validate_binding_data(_binding_data, _requirement), do: {:error, :credential_id_required}

  defp validate_binding_data(binding_data, requirement, %Scope{} = scope)
       when is_map(binding_data) and is_map(requirement) do
    with :ok <- validate_binding_data(binding_data, requirement),
         {:ok, credential_id} <- fetch_string(binding_data, "credential_id"),
         {:ok, options} <- options_for_requirement(requirement, scope, limit: :all),
         true <- credential_option_available?(options, credential_id) do
      :ok
    else
      false -> {:error, :credential_not_available}
      {:error, _reason} = error -> error
    end
  end

  defp validate_binding_data(binding_data, requirement, _scope),
    do: validate_binding_data(binding_data, requirement)

  defp options_for_requirement(requirement, scope, opts \\ [])

  defp options_for_requirement(requirement, %Scope{} = scope, opts)
       when is_map(requirement) and is_list(opts) do
    with {:ok, organization_id} <- fetch_organization_id(scope) do
      external_auth_opts =
        []
        |> maybe_put(:provider_filter, list_param(requirement, "provider"))
        |> maybe_put(:auth_types, list_param(requirement, "auth_type"))

      case ExternalAuth.list_credential_options(scope, organization_id, external_auth_opts) do
        {:ok, options} ->
          user_id = scope_user_id_value(scope)

          options =
            options
            |> filter_to_current_user(user_id)
            |> maybe_sync_single_workos_oauth_option(requirement, scope, organization_id)
            |> filter_to_current_user(user_id)
            |> apply_search(Keyword.get(opts, :q, ""))
            |> apply_limit(Keyword.get(opts, :limit, @max_options))

          {:ok, options}

        {:error, _} = error ->
          error
      end
    end
  end

  defp options_for_requirement(_requirement, _scope, _opts), do: {:error, :invalid_scope}

  defp credential_option_available?(options, credential_id) when is_list(options) do
    Enum.any?(options, fn option ->
      fetch_value(option, "id") == credential_id
    end)
  end

  defp apply_limit(options, :all), do: options

  defp apply_limit(options, limit) when is_integer(limit) and limit >= 0,
    do: Enum.take(options, limit)

  defp apply_limit(options, _limit), do: Enum.take(options, @max_options)

  defp maybe_sync_single_workos_oauth_option(options, spec, scope, organization_id)
       when is_list(options) do
    if options == [] do
      sync_single_workos_oauth_option(spec, scope, organization_id, options)
    else
      options
    end
  end

  defp sync_single_workos_oauth_option(spec, scope, organization_id, fallback_options) do
    with {:ok, provider} <- single_spec_value(spec, "provider"),
         {:ok, "oauth"} <- single_spec_value(spec, "auth_type"),
         {:ok, provider_mod} <- ProviderCatalog.oauth_provider_module(provider),
         {:ok, %{active: true} = status} <- provider_mod.check_connection(scope, organization_id),
         {:ok, _connection} <-
           ExternalAuth.upsert_oauth_connection(scope, organization_id, provider, status),
         {:ok, options} <-
           ExternalAuth.list_credential_options(scope, organization_id,
             provider_filter: [provider],
             auth_types: [:oauth]
           ) do
      options
    else
      _reason -> fallback_options
    end
  end

  defp single_spec_value(spec, key) when is_map(spec) and is_binary(key) do
    case list_param(spec, key) do
      [value] -> {:ok, value}
      _values -> {:error, :single_value_required}
    end
  end

  defp filter_to_current_user(options, user_id) when is_binary(user_id) do
    Enum.filter(options, fn option ->
      option_user_id = Map.get(option, :owner_user_id) || Map.get(option, "owner_user_id")
      option_user_id == user_id
    end)
  end

  defp filter_to_current_user(options, _user_id), do: options

  defp scope_user_id_value(%Scope{user: %{id: user_id}}) when is_binary(user_id), do: user_id
  defp scope_user_id_value(%Scope{}), do: nil

  defp apply_search(options, query) do
    case normalize_query(query) do
      nil ->
        options

      query ->
        Enum.filter(options, &matches_query?(&1, query))
    end
  end

  defp matches_query?(option, query) when is_map(option) do
    option
    |> searchable_fields()
    |> Enum.any?(fn value ->
      value
      |> String.downcase()
      |> String.contains?(query)
    end)
  end

  defp matches_query?(_option, _query), do: false

  defp searchable_fields(option) do
    [
      fetch_value(option, "display_name"),
      fetch_value(option, "provider_label"),
      fetch_value(option, "provider"),
      fetch_value(option, "auth_type"),
      fetch_value(option, "owner_display_name"),
      fetch_value(option, "id")
    ]
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
  end

  defp fetch_string(map, key) when is_map(map) and is_binary(key) do
    case fetch_value(map, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:missing_field, key}}
          trimmed -> {:ok, trimmed}
        end

      _ ->
        {:error, {:missing_field, key}}
    end
  end

  defp fetch_organization_id(%Scope{organization_id: organization_id})
       when is_binary(organization_id) and organization_id != "",
       do: {:ok, organization_id}

  defp fetch_organization_id(_scope), do: {:error, :organization_scope_required}

  defp list_param(spec, key) do
    case fetch_value(spec, key) do
      nil -> []
      value when is_binary(value) -> [value]
      values when is_list(values) -> Enum.filter(values, &is_binary/1)
      _ -> []
    end
  end

  defp maybe_put(opts, _key, []) when is_list(opts), do: opts
  defp maybe_put(opts, key, value) when is_list(opts), do: Keyword.put(opts, key, value)
  defp maybe_put(map, _key, nil) when is_map(map), do: map
  defp maybe_put(map, _key, []) when is_map(map), do: map
  defp maybe_put(map, key, value) when is_map(map), do: Map.put(map, key, value)

  defp normalize_query(query) do
    query
    |> normalize_string()
    |> case do
      nil -> nil
      value -> String.downcase(value)
    end
  end

  defp normalize_string(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_string(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> normalize_string()
  end

  defp normalize_string(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> normalize_string()
  end

  defp normalize_string(value) when is_float(value) do
    value
    |> to_string()
    |> normalize_string()
  end

  defp normalize_string(_value), do: nil

  defp fetch_value(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp fetch_value(map, key) when is_map(map) and is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> fetch_known_atom_value(map, key)
    end
  end

  defp fetch_value(_map, _key), do: nil

  defp fetch_known_atom_value(map, "auth_type"), do: Map.get(map, :auth_type)
  defp fetch_known_atom_value(map, "binding_data"), do: Map.get(map, :binding_data)
  defp fetch_known_atom_value(map, "credential_id"), do: Map.get(map, :credential_id)
  defp fetch_known_atom_value(map, "credentials"), do: Map.get(map, :credentials)
  defp fetch_known_atom_value(map, "current_scope"), do: Map.get(map, :current_scope)
  defp fetch_known_atom_value(map, "id"), do: Map.get(map, :id)
  defp fetch_known_atom_value(map, "owner_user_id"), do: Map.get(map, :owner_user_id)
  defp fetch_known_atom_value(map, "provider"), do: Map.get(map, :provider)
  defp fetch_known_atom_value(map, "requirement_key"), do: Map.get(map, :requirement_key)
  defp fetch_known_atom_value(map, "secret"), do: Map.get(map, :secret)
  defp fetch_known_atom_value(map, "step_id"), do: Map.get(map, :step_id)
  defp fetch_known_atom_value(map, "user_id"), do: Map.get(map, :user_id)
  defp fetch_known_atom_value(map, "value"), do: Map.get(map, :value)

  defp fetch_known_atom_value(map, "workflow_definition_id"),
    do: Map.get(map, :workflow_definition_id)

  defp fetch_known_atom_value(map, "workos_organization_id"),
    do: Map.get(map, :workos_organization_id)

  defp fetch_known_atom_value(_map, _key), do: nil

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp format_reason(reason), do: inspect(reason)

  defp atomize_keys(attrs) do
    Map.new(attrs, fn {key, value} -> {binding_attr_key(key), value} end)
  end

  defp binding_attr_key("binding_data"), do: :binding_data
  defp binding_attr_key("requirement_key"), do: :requirement_key
  defp binding_attr_key("step_id"), do: :step_id
  defp binding_attr_key("user_id"), do: :user_id
  defp binding_attr_key("workflow_definition_id"), do: :workflow_definition_id
  defp binding_attr_key("workos_organization_id"), do: :workos_organization_id
  defp binding_attr_key(key), do: key

  defp api_key_placeholder("openai_api_key"), do: "sk-..."
  defp api_key_placeholder("anthropic_api_key"), do: "sk-ant-..."
  defp api_key_placeholder("github_api_key"), do: "ghp_..."
  defp api_key_placeholder(_provider_id), do: "Enter API key"
end
