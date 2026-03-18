defmodule Fizz.Workflows do
  import Ecto.Query

  alias Ecto.Multi
  alias Fizz.Accounts.{Project, Scope}
  alias Fizz.Repo
  alias Fizz.Workflows.Compiler
  alias Fizz.Workflows.{WorkflowDefinition, WorkflowDefinitionVersion}

  @default_snapshot_attrs %{
    steps: [],
    connections: [],
    step_groups: [],
    viewport: WorkflowDefinitionVersion.default_viewport(),
    settings: %{}
  }

  @type error_reason ::
          :definition_not_found
          | :not_a_draft
          | :project_scope_required
          | :published_version_not_found
          | :unauthenticated
          | :version_not_found
          | Ecto.Changeset.t()

  @spec create_definition(Scope.t() | nil, map()) ::
          {:ok, %{definition: %WorkflowDefinition{}, draft: %WorkflowDefinitionVersion{}}}
          | {:error, error_reason()}
  def create_definition(scope, attrs) when is_map(attrs) do
    with {:ok, project} <- project_from_scope(scope),
         {:ok, user_id} <- user_id_from_scope(scope) do
      definition_attrs =
        attrs
        |> Map.put(:project_id, project.id)
        |> Map.put(:workos_organization_id, project.workos_organization_id)
        |> Map.put(:created_by_user_id, user_id)

      Multi.new()
      |> Multi.insert(
        :definition,
        WorkflowDefinition.changeset(%WorkflowDefinition{}, definition_attrs)
      )
      |> Multi.insert(:draft, fn %{definition: definition} ->
        WorkflowDefinitionVersion.save_changeset(
          %WorkflowDefinitionVersion{},
          initial_draft_attrs(definition.id)
        )
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{definition: definition, draft: draft}} ->
          {:ok, %{definition: definition, draft: draft}}

        {:error, _operation, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  def create_definition(_scope, _attrs), do: {:error, :project_scope_required}

  @spec save_draft(Scope.t() | nil, %WorkflowDefinitionVersion{} | String.t(), map()) ::
          {:ok, %WorkflowDefinitionVersion{}} | {:error, error_reason()}
  def save_draft(scope, version, attrs) when is_map(attrs) do
    with {:ok, version_record} <- fetch_version(scope, version),
         :ok <- ensure_draft(version_record) do
      version_record
      |> WorkflowDefinitionVersion.save_changeset(normalize_snapshot_attrs(attrs))
      |> Repo.update()
    end
  end

  def save_draft(_scope, _version, _attrs), do: {:error, :project_scope_required}

  @spec publish_draft(Scope.t() | nil, %WorkflowDefinitionVersion{} | String.t()) ::
          {:ok, %WorkflowDefinitionVersion{}} | {:error, error_reason()}
  def publish_draft(scope, version) do
    with {:ok, version_record} <- fetch_version(scope, version),
         :ok <- ensure_draft(version_record),
         {:ok, user_id} <- user_id_from_scope(scope) do
      published_at = DateTime.utc_now()

      changeset =
        WorkflowDefinitionVersion.publish_changeset(version_record, %{
          status: :published,
          compiled_hash: provisional_compiled_hash(),
          published_at: published_at,
          published_by_user_id: user_id
        })

      if changeset.valid? do
        compiled_version = Ecto.Changeset.apply_changes(changeset)

        case Compiler.compile(compiled_version) do
          {:ok, _workflow, compiled_hash} ->
            changeset
            |> Ecto.Changeset.put_change(:compiled_hash, compiled_hash)
            |> Repo.update()

          {:error, errors} ->
            {:error, add_compile_errors(changeset, errors)}
        end
      else
        {:error, changeset}
      end
    end
  end

  @spec edit_definition(Scope.t() | nil, %WorkflowDefinition{} | String.t()) ::
          {:ok, %WorkflowDefinitionVersion{}} | {:error, error_reason()}
  def edit_definition(scope, definition) do
    with {:ok, definition_record} <- fetch_definition(scope, definition) do
      case latest_draft_version(definition_record.id) do
        %WorkflowDefinitionVersion{} = draft ->
          {:ok, draft}

        nil ->
          case latest_published_version(definition_record.id) do
            %WorkflowDefinitionVersion{} = published_version ->
              %WorkflowDefinitionVersion{}
              |> WorkflowDefinitionVersion.save_changeset(
                clone_draft_attrs(definition_record.id, published_version)
              )
              |> Repo.insert()

            nil ->
              {:error, :published_version_not_found}
          end
      end
    end
  end

  @spec archive_definition(Scope.t() | nil, %WorkflowDefinition{} | String.t()) ::
          {:ok, %WorkflowDefinition{}} | {:error, error_reason()}
  def archive_definition(scope, definition) do
    with {:ok, definition_record} <- fetch_definition(scope, definition) do
      archived_at = definition_record.archived_at || DateTime.utc_now()

      definition_record
      |> WorkflowDefinition.changeset(%{archived_at: archived_at})
      |> Repo.update()
    end
  end

  @spec get_definition(Scope.t() | nil, String.t()) ::
          {:ok, %WorkflowDefinition{}} | {:error, error_reason()}
  def get_definition(scope, id) when is_binary(id) do
    with {:ok, project} <- project_from_scope(scope) do
      versions_query =
        from(version in WorkflowDefinitionVersion,
          order_by: [desc: version.version]
        )

      definition =
        from(definition in WorkflowDefinition,
          where: definition.project_id == ^project.id and definition.id == ^id,
          preload: [versions: ^versions_query]
        )
        |> Repo.one()

      case definition do
        %WorkflowDefinition{} = definition_record -> {:ok, definition_record}
        nil -> {:error, :definition_not_found}
      end
    end
  end

  @spec list_definitions(Scope.t() | nil) ::
          {:ok, [%WorkflowDefinition{}]} | {:error, error_reason()}
  def list_definitions(scope) do
    with {:ok, project} <- project_from_scope(scope) do
      definitions =
        from(definition in WorkflowDefinition,
          where: definition.project_id == ^project.id and is_nil(definition.archived_at),
          order_by: [asc: definition.name]
        )
        |> Repo.all()

      {:ok, definitions}
    end
  end

  defp fetch_definition(scope, %WorkflowDefinition{id: id}), do: fetch_definition(scope, id)

  defp fetch_definition(scope, id) when is_binary(id) do
    with {:ok, project} <- project_from_scope(scope) do
      definition =
        from(definition in WorkflowDefinition,
          where: definition.project_id == ^project.id and definition.id == ^id
        )
        |> Repo.one()

      case definition do
        %WorkflowDefinition{} = definition_record -> {:ok, definition_record}
        nil -> {:error, :definition_not_found}
      end
    end
  end

  defp fetch_version(scope, %WorkflowDefinitionVersion{id: id}), do: fetch_version(scope, id)

  defp fetch_version(scope, id) when is_binary(id) do
    with {:ok, project} <- project_from_scope(scope) do
      version =
        from(version in WorkflowDefinitionVersion,
          join: definition in assoc(version, :workflow_definition),
          where: definition.project_id == ^project.id and version.id == ^id
        )
        |> Repo.one()

      case version do
        %WorkflowDefinitionVersion{} = version_record -> {:ok, version_record}
        nil -> {:error, :version_not_found}
      end
    end
  end

  defp project_from_scope(%Scope{project: %Project{} = project}), do: {:ok, project}
  defp project_from_scope(_scope), do: {:error, :project_scope_required}

  defp user_id_from_scope(%Scope{user: %{id: user_id}}) when is_binary(user_id),
    do: {:ok, user_id}

  defp user_id_from_scope(_scope), do: {:error, :unauthenticated}

  defp ensure_draft(%WorkflowDefinitionVersion{status: :draft}), do: :ok
  defp ensure_draft(%WorkflowDefinitionVersion{}), do: {:error, :not_a_draft}

  defp initial_draft_attrs(definition_id) do
    Map.merge(@default_snapshot_attrs, %{
      workflow_definition_id: definition_id,
      version: 1,
      status: :draft
    })
  end

  defp clone_draft_attrs(definition_id, published_version) do
    published_version
    |> snapshot_attrs()
    |> Map.merge(%{
      workflow_definition_id: definition_id,
      version: published_version.version + 1,
      status: :draft,
      compiled_hash: nil,
      published_at: nil,
      published_by_user_id: nil
    })
  end

  defp snapshot_attrs(version) do
    %{
      steps: Enum.map(version.steps, &embed_to_attrs/1),
      connections: Enum.map(version.connections, &embed_to_attrs/1),
      step_groups: Enum.map(version.step_groups, &embed_to_attrs/1),
      viewport: version.viewport || WorkflowDefinitionVersion.default_viewport(),
      settings: version.settings || %{}
    }
  end

  defp latest_draft_version(definition_id) do
    from(version in WorkflowDefinitionVersion,
      where: version.workflow_definition_id == ^definition_id and version.status == :draft,
      order_by: [desc: version.version],
      limit: 1
    )
    |> Repo.one()
  end

  defp latest_published_version(definition_id) do
    from(version in WorkflowDefinitionVersion,
      where: version.workflow_definition_id == ^definition_id and version.status == :published,
      order_by: [desc: version.version],
      limit: 1
    )
    |> Repo.one()
  end

  defp normalize_snapshot_attrs(attrs) when is_map(attrs) do
    attrs
    |> put_default_if_missing(:steps, [])
    |> put_default_if_missing(:connections, [])
    |> put_default_if_missing(:step_groups, [])
    |> put_default_if_missing(:viewport, WorkflowDefinitionVersion.default_viewport())
    |> put_default_if_missing(:settings, %{})
  end

  defp put_default_if_missing(attrs, field, default) do
    field_name = Atom.to_string(field)

    cond do
      Map.has_key?(attrs, field) -> attrs
      Map.has_key?(attrs, field_name) -> attrs
      true -> Map.put(attrs, field, default)
    end
  end

  defp embed_to_attrs(%_{} = embed), do: Map.from_struct(embed)
  defp embed_to_attrs(embed) when is_map(embed), do: embed

  defp provisional_compiled_hash do
    String.duplicate("0", 64)
  end

  defp add_compile_errors(changeset, errors) do
    Enum.reduce(errors, changeset, fn error, acc ->
      Ecto.Changeset.add_error(acc, :steps, error.message)
    end)
  end
end
