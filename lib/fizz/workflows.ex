defmodule Fizz.Workflows do
  @moduledoc """
  Context for managing workflows, versions, drafts, and related functionality.

  All functions that require authorization accept a `Scope` as the first argument
  following Phoenix conventions. Permission checks are performed through the
  `Fizz.Accounts.Scope` module.

  ## Authorization

  - Use `Scope.can_view_workflow?/2` to check view permissions
  - Use `Scope.can_edit_workflow?/2` to check edit permissions
  - Workflow access is scoped to the active workspace in `Scope`

  ## Examples

      # List workflows accessible to the user
      Workflows.list_workflows(scope)

      # Get a workflow (returns error if not accessible)
      {:ok, workflow} = Workflows.get_workflow(scope, workflow_id)

      # Update a workflow (requires edit permission)
      {:ok, workflow} = Workflows.update_workflow(scope, workflow, attrs)
  """

  import Ecto.Query, warn: false
  alias Fizz.Repo

  alias Fizz.Workflows.{Workflow, WorkflowVersion, WorkflowDraft}
  alias Fizz.Executions.Execution
  alias Fizz.Accounts.Scope

  @type workflow_params :: %{
          required(:name) => String.t(),
          optional(:description) => String.t(),
          optional(:current_version_tag) => String.t()
        }

  @type workflow_version_params :: %{
          required(:version_tag) => String.t(),
          optional(:changelog) => String.t()
        }

  @doc """
  Lists workflows accessible to the given scope.
  """
  @spec list_workflows(Scope.t() | nil) :: [Workflow.t()]
  def list_workflows(%Scope{workspace: %{id: workspace_id}} = scope)
      when is_binary(workspace_id) do
    case Scope.can_view_workflow?(scope, %Workflow{workspace_id: workspace_id}) do
      true ->
        query =
          from w in Workflow,
            where: w.workspace_id == ^workspace_id,
            order_by: [desc: w.updated_at]

        Repo.all(query) |> Repo.preload([:user, :workspace])

      false ->
        []
    end
  end

  def list_workflows(_scope), do: []

  @doc false
  @spec list_public_workflows() :: [Workflow.t()]
  def list_public_workflows, do: []

  @doc """
  Determines the access level/state for a workflow relative to a scope.

  Returns:
  - `:admin` for workspace admin (or organization admin) write access
  - `:member` for workspace member write access
  - `:viewer` for workspace viewer read-only access
  - `nil` for no access
  """
  @spec workflow_access_state(Scope.t() | nil, Workflow.t()) ::
          :admin | :member | :viewer | nil
  def workflow_access_state(%Scope{} = scope, %Workflow{} = workflow) do
    cond do
      Scope.can_edit_workflow?(scope, workflow) and
          (Scope.workspace_admin?(scope) or Scope.organization_admin?(scope)) ->
        :admin

      Scope.can_edit_workflow?(scope, workflow) ->
        :member

      Scope.can_view_workflow?(scope, workflow) ->
        :viewer

      true ->
        nil
    end
  end

  def workflow_access_state(_scope, _workflow), do: nil

  @doc """
  Lists workflows owned by the user in the scope.
  """
  @spec list_owned_workflows(Scope.t()) :: [Workflow.t()]
  def list_owned_workflows(%Scope{workspace: %{id: workspace_id}, user: %{id: user_id}} = scope)
      when is_binary(workspace_id) do
    case Scope.can_view_workflow?(scope, %Workflow{workspace_id: workspace_id}) do
      true ->
        Repo.all(
          from w in Workflow,
            where: w.workspace_id == ^workspace_id and w.user_id == ^user_id,
            order_by: [desc: w.updated_at]
        )

      false ->
        []
    end
  end

  def list_owned_workflows(%Scope{}), do: []

  @doc """
  Returns a query for active workflows.
  """
  def list_active_workflows_query do
    from w in Workflow, where: w.status == :active
  end

  # ============================================================================

  @doc """
  Gets a single workflow by ID, checking access permissions.

  Returns `{:ok, workflow}` if the user has access, `{:error, :not_found}` otherwise.
  """
  @spec get_workflow(Scope.t() | nil, String.t() | Ecto.UUID.t()) ::
          {:ok, Workflow.t()} | {:error, :not_found}
  def get_workflow(scope, id), do: do_get_workflow(id, scope)

  @doc """
  Finds an active published workflow by its configured webhook path and method.
  """
  @spec get_active_workflow_by_webhook(String.t(), String.t()) :: Workflow.t() | nil
  def get_active_workflow_by_webhook(path, method) do
    # method should be uppercase for consistency
    method = String.upcase(method)

    query =
      from w in Workflow,
        join: v in assoc(w, :published_version),
        where: w.status == :active,
        where:
          fragment(
            "EXISTS (SELECT 1 FROM jsonb_array_elements(?) AS s WHERE s->>'type_id' = 'webhook_trigger' AND COALESCE(s->'config'->>'path', s->>'id') = ? AND (s->'config'->>'http_method' = ? OR s->'config'->>'http_method' = 'ANY' OR (s->'config'->>'http_method' IS NULL AND ? = 'POST')))",
            v.steps,
            ^path,
            ^method,
            ^method
          ),
        limit: 1

    Repo.one(query)
  end

  @doc """
  Finds a workflow by its DRAFT webhook path and method.
  Ignores status (allows drafts).
  """
  @spec get_workflow_by_webhook_draft_path(String.t(), String.t()) :: Workflow.t() | nil
  def get_workflow_by_webhook_draft_path(path, method) do
    method = String.upcase(method)

    query =
      from w in Workflow,
        join: d in assoc(w, :draft),
        where:
          fragment(
            "EXISTS (SELECT 1 FROM jsonb_array_elements(?) AS s WHERE s->>'type_id' = 'webhook_trigger' AND COALESCE(s->'config'->>'path', s->>'id') = ? AND (s->'config'->>'http_method' = ? OR s->'config'->>'http_method' = 'ANY' OR (s->'config'->>'http_method' IS NULL AND ? = 'POST')))",
            d.steps,
            ^path,
            ^method,
            ^method
          ),
        limit: 1

    Repo.one(query)
  end

  defp do_get_workflow(id, scope) do
    case Repo.get(Workflow, id) do
      nil ->
        {:error, :not_found}

      %Workflow{} = workflow ->
        if Scope.can_view_workflow?(scope, workflow) do
          {:ok, workflow}
        else
          {:error, :not_found}
        end
    end
  end

  @doc """
  Gets a workflow with its draft preloaded.

  Returns `{:ok, workflow}` with draft loaded, or `{:error, :not_found}`.
  """
  @spec get_workflow_with_draft(Scope.t() | nil, String.t() | Ecto.UUID.t()) ::
          {:ok, Workflow.t()} | {:error, :not_found}
  def get_workflow_with_draft(scope, id), do: do_get_workflow_with_draft(id, scope)

  defp do_get_workflow_with_draft(id, scope) do
    case Repo.get(Workflow, id) |> Repo.preload([:draft, :workspace]) do
      nil ->
        {:error, :not_found}

      %Workflow{} = workflow ->
        if Scope.can_view_workflow?(scope, workflow) do
          {:ok, %{workflow | draft: ensure_draft_defaults(workflow.draft)}}
        else
          {:error, :not_found}
        end
    end
  end

  # ============================================================================
  # Create/Update/Delete Functions
  # ============================================================================

  @doc """
  Creates a new workflow for the user in the scope.

  Requires member/admin workflow permissions in the active workspace.
  """
  @spec create_workflow(Scope.t(), workflow_params()) ::
          {:ok, Workflow.t()} | {:error, Ecto.Changeset.t() | :access_denied}
  def create_workflow(
        %Scope{workspace: %{id: workspace_id}, user: %{id: user_id}} = scope,
        attrs
      )
      when is_binary(workspace_id) do
    seed_workflow = %Workflow{workspace_id: workspace_id}

    case Scope.can_edit_workflow?(scope, seed_workflow) do
      true ->
        attrs
        |> Map.put(:workspace_id, workspace_id)
        |> Map.put(:user_id, user_id)
        |> then(fn workflow_attrs ->
          %Workflow{}
          |> Workflow.create_changeset(workflow_attrs)
          |> Repo.insert()
        end)

      false ->
        {:error, :access_denied}
    end
  end

  def create_workflow(%Scope{}, _attrs), do: {:error, :access_denied}

  @doc """
  Updates a workflow, checking edit permissions.

  Returns `{:ok, workflow}` if successful, `{:error, changeset | :access_denied}` otherwise.
  """
  @spec update_workflow(Scope.t(), Workflow.t(), workflow_params()) ::
          {:ok, Workflow.t()} | {:error, Ecto.Changeset.t() | :access_denied}
  def update_workflow(%Scope{} = scope, %Workflow{} = workflow, attrs) do
    if Scope.can_edit_workflow?(scope, workflow) do
      workflow
      |> Workflow.update_changeset(attrs)
      |> Repo.update()
    else
      {:error, :access_denied}
    end
  end

  @doc """
  Deletes a workflow, checking edit permissions.
  """
  @spec delete_workflow(Scope.t(), Workflow.t()) ::
          {:ok, Workflow.t()} | {:error, :access_denied}
  def delete_workflow(%Scope{} = scope, %Workflow{} = workflow) do
    if Scope.can_edit_workflow?(scope, workflow) do
      Fizz.Runtime.Triggers.Activator.deactivate(workflow.id)
      Repo.delete(workflow)
    else
      {:error, :access_denied}
    end
  end

  @doc """
  Archives a workflow, checking edit permissions.
  """
  @spec archive_workflow(Scope.t(), Workflow.t()) ::
          {:ok, Workflow.t()} | {:error, Ecto.Changeset.t() | :access_denied}
  def archive_workflow(%Scope{} = scope, %Workflow{} = workflow) do
    Fizz.Runtime.Triggers.Activator.deactivate(workflow.id)
    update_workflow(scope, workflow, %{status: :archived})
  end

  @doc """
  Duplicates a workflow for the current user.

  Returns `{:ok, workflow}` if successful, `{:error, reason}` otherwise.
  """
  @spec duplicate_workflow(Scope.t(), Workflow.t()) ::
          {:ok, Workflow.t()} | {:error, :access_denied | term()}
  def duplicate_workflow(%Scope{} = scope, %Workflow{} = workflow) do
    if Scope.can_view_workflow?(scope, workflow) do
      Repo.transaction(fn ->
        workflow = Repo.preload(workflow, :draft)

        draft =
          workflow.draft ||
            %WorkflowDraft{steps: [], connections: [], groups: [], settings: %{}}

        workflow_attrs = %{
          name: "Copy of #{workflow.name}",
          description: workflow.description,
          status: :draft,
          current_version_tag: nil,
          published_version_id: nil
        }

        with {:ok, duplicated} <- create_workflow(scope, workflow_attrs),
             {:ok, _duplicated_draft} <- insert_duplicate_draft(duplicated.id, draft) do
          duplicated
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, duplicated} -> {:ok, duplicated}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :access_denied}
    end
  end

  # ============================================================================
  # Publishing Functions
  # ============================================================================

  @doc """
  Publishes a workflow version, creating a new published version.

  Returns `{:ok, {workflow, version}}` if successful, `{:error, reason}` otherwise.
  """
  @spec publish_workflow(Scope.t(), Workflow.t(), workflow_version_params()) ::
          {:ok, {Workflow.t(), WorkflowVersion.t()}} | {:error, any()}
  def publish_workflow(%Scope{} = scope, %Workflow{} = workflow, version_attrs) do
    if Scope.can_edit_workflow?(scope, workflow) do
      Repo.transaction(fn ->
        case Repo.get_by(WorkflowDraft, workflow_id: workflow.id) do
          nil ->
            Repo.rollback(:draft_not_found)

          draft ->
            case Fizz.Workflows.Validator.validate(draft) do
              :ok ->
                version_attrs =
                  version_attrs
                  |> Map.put(:workflow_id, workflow.id)
                  |> Map.put(
                    :source_hash,
                    WorkflowVersion.compute_source_hash(
                      List.wrap(draft.steps),
                      List.wrap(draft.connections),
                      List.wrap(draft.groups)
                    )
                  )
                  |> Map.put(:steps, Enum.map(List.wrap(draft.steps), &Map.from_struct/1))
                  |> Map.put(
                    :connections,
                    Enum.map(List.wrap(draft.connections), &Map.from_struct/1)
                  )
                  |> Map.put(:groups, Enum.map(List.wrap(draft.groups), &Map.from_struct/1))
                  |> Map.put(:published_by, scope.user.id)

                with {:ok, version} <-
                       %WorkflowVersion{}
                       |> WorkflowVersion.changeset(version_attrs)
                       |> Repo.insert(),
                     {:ok, updated_workflow} <-
                       workflow
                       |> Workflow.update_changeset(%{
                         published_version_id: version.id,
                         status: :active,
                         current_version_tag: version.version_tag
                       })
                       |> Repo.update() do
                  {updated_workflow, version}
                else
                  {:error, reason} -> Repo.rollback(reason)
                end

              {:error, errors} ->
                Repo.rollback({:invalid_workflow, errors})
            end
        end
      end)
      |> case do
        {:ok, {updated_workflow, version}} ->
          Fizz.Runtime.Triggers.Activator.activate(updated_workflow)
          {:ok, {updated_workflow, version}}

        error ->
          error
      end
    else
      {:error, :access_denied}
    end
  end

  # ============================================================================
  # Version Functions
  # ============================================================================

  @doc """
  Gets a workflow version by ID, checking access permissions.

  Returns `{:ok, version}` if the user has access, `{:error, :not_found}` otherwise.
  """
  @spec get_workflow_version(Scope.t() | nil, String.t() | Ecto.UUID.t()) ::
          {:ok, WorkflowVersion.t()} | {:error, :not_found}
  def get_workflow_version(scope, id) do
    case Repo.get(WorkflowVersion, id) |> Repo.preload(:workflow) do
      nil ->
        {:error, :not_found}

      %WorkflowVersion{workflow: workflow} = version ->
        if Scope.can_view_workflow?(scope, workflow) do
          {:ok, version}
        else
          {:error, :not_found}
        end
    end
  end

  @doc """
  Lists versions for a workflow, checking access permissions.

  Returns a list of versions if the user has access, empty list otherwise.
  """
  @spec list_workflow_versions(Scope.t() | nil, Workflow.t()) :: [WorkflowVersion.t()]
  def list_workflow_versions(scope, %Workflow{} = workflow) do
    if Scope.can_view_workflow?(scope, workflow) do
      Repo.all(
        from v in WorkflowVersion,
          where: v.workflow_id == ^workflow.id,
          order_by: [desc: v.published_at]
      )
    else
      []
    end
  end

  # ============================================================================
  # Draft Functions
  # ============================================================================

  @doc """
  Gets a workflow draft by workflow ID.

  Returns `{:ok, draft}` if found, `{:error, :not_found}` otherwise.
  """
  @spec get_draft(Scope.t() | nil, String.t() | Ecto.UUID.t()) ::
          {:ok, WorkflowDraft.t()} | {:error, :not_found}
  def get_draft(scope, workflow_id) do
    with {:ok, workflow} <- get_workflow(scope, workflow_id) do
      case Repo.get_by(WorkflowDraft, workflow_id: workflow.id) do
        nil -> {:error, :not_found}
        draft -> {:ok, ensure_draft_defaults(draft)}
      end
    end
  end

  @doc """
  Updates a workflow draft, checking edit permissions.

  Returns `{:ok, draft}` if successful, `{:error, changeset | :access_denied}` otherwise.
  """
  @spec update_workflow_draft(Scope.t(), Workflow.t(), map()) ::
          {:ok, WorkflowDraft.t()} | {:error, Ecto.Changeset.t() | :access_denied}
  def update_workflow_draft(%Scope{} = scope, %Workflow{} = workflow, attrs) do
    if Scope.can_edit_workflow?(scope, workflow) do
      case Repo.get_by(WorkflowDraft, workflow_id: workflow.id) do
        nil ->
          # Create draft if it doesn't exist
          %WorkflowDraft{}
          |> WorkflowDraft.changeset(Map.put(attrs, :workflow_id, workflow.id))
          |> Repo.insert()

        draft ->
          draft
          |> WorkflowDraft.changeset(attrs)
          |> Repo.update()
      end
    else
      {:error, :access_denied}
    end
  end

  # ============================================================================
  # Execution Functions
  # ============================================================================

  @doc """
  Gets executions for a workflow, checking access permissions.

  Returns a list of executions if the user has access, empty list otherwise.
  """
  @spec list_workflow_executions(Scope.t() | nil, Workflow.t()) :: [Execution.t()]
  def list_workflow_executions(scope, %Workflow{} = workflow) do
    if Scope.can_view_workflow?(scope, workflow) do
      Repo.all(
        from e in Execution,
          where: e.workflow_id == ^workflow.id,
          order_by: [desc: e.inserted_at],
          limit: 100
      )
    else
      []
    end
  end

  @doc """
  Counts executions for a workflow by status.

  Returns a map with status counts.
  """
  @spec count_workflow_executions(Workflow.t()) :: %{optional(atom()) => non_neg_integer()}
  def count_workflow_executions(%Workflow{} = workflow) do
    query =
      from e in Execution,
        where: e.workflow_id == ^workflow.id,
        select: {e.status, count(e.id)},
        group_by: e.status

    Repo.all(query) |> Map.new()
  end

  # ============================================================================
  # Trigger Functions
  # ============================================================================

  @trigger_type_ids ["webhook_trigger", "schedule_trigger", "manual_input", "event_trigger"]

  @doc "Returns all trigger steps for the workflow."
  @spec triggers(Workflow.t()) :: [map()]
  def triggers(%Workflow{} = workflow) do
    workflow = Repo.preload(workflow, :draft)

    case workflow.draft do
      nil -> []
      draft -> Enum.filter(draft.steps || [], &is_trigger_step?/1)
    end
  end

  @doc "Returns all trigger steps of a specific type."
  @spec triggers_of_type(Workflow.t(), atom() | String.t()) :: [map()]
  def triggers_of_type(%Workflow{} = workflow, type) do
    workflow = Repo.preload(workflow, :draft)
    trigger_type_id = trigger_type_to_step_type_id(type)

    case workflow.draft do
      nil -> []
      draft -> Enum.filter(draft.steps || [], &(&1.type_id == trigger_type_id))
    end
  end

  @doc "Checks if the workflow has at least one trigger of a specific type."
  @spec has_trigger_type?(Workflow.t(), atom() | String.t()) :: boolean()
  def has_trigger_type?(%Workflow{} = workflow, type) do
    workflow = Repo.preload(workflow, :draft)
    trigger_type_id = trigger_type_to_step_type_id(type)

    case workflow.draft do
      nil -> false
      draft -> Enum.any?(draft.steps || [], &(&1.type_id == trigger_type_id))
    end
  end

  @doc "Returns a count of triggers grouped by type."
  @spec trigger_counts(Workflow.t()) :: %{String.t() => non_neg_integer()}
  def trigger_counts(%Workflow{} = workflow) do
    workflow
    |> triggers()
    |> Enum.group_by(& &1.type_id)
    |> Map.new(fn {type_id, steps} -> {type_id, length(steps)} end)
  end

  defp is_trigger_step?(%{type_id: type_id}) do
    type_id in @trigger_type_ids
  end

  defp trigger_type_to_step_type_id(:webhook), do: "webhook_trigger"
  defp trigger_type_to_step_type_id(:schedule), do: "schedule_trigger"
  defp trigger_type_to_step_type_id(:manual), do: "manual_input"
  defp trigger_type_to_step_type_id(:event), do: "event_trigger"
  defp trigger_type_to_step_type_id(type) when is_binary(type), do: type

  # ============================================================================
  # Step Identity
  # ============================================================================

  @doc """
  Converts a display name into a key-safe step ID.

  Uses underscores (not hyphens) to create identifiers safe for use as:
  - Map keys in execution context
  - Runic component names
  - Expression variable names (e.g., `steps.my_step.json`)

  ## Examples

      iex> to_step_id("HTTP Request")
      "http_request"

      iex> to_step_id("My Step 1")
      "my_step_1"
  """
  @spec to_step_id(String.t()) :: String.t()
  def to_step_id(name) when is_binary(name) do
    name
    |> String.downcase()
    # Use the `u` flag so the regex treats full Unicode codepoints (not raw bytes).
    # Without `u`, multi-byte chars like — (U+2014, 0xE2 0x80 0x94) are matched only
    # by their first byte, leaving orphaned bytes that corrupt the resulting string.
    |> String.replace(~r/[^\w\s]/u, "")
    |> String.replace(~r/[\s]+/u, "_")
    |> String.replace(~r/_+/, "_")
    |> String.trim("_")
  end

  def to_step_id(_), do: ""

  @doc """
  Generates a unique step name and ID pair for a workflow.

  Returns `{name, step_id}` where both are unique within the workflow.
  Handles "Name", "Name 2", "Name 3" etc. for display names,
  and "name", "name_2", "name_3" for step IDs.

  ## Examples

      iex> generate_unique_step_identity([], "HTTP Request")
      {"HTTP Request", "http_request"}

      iex> generate_unique_step_identity([%{name: "HTTP Request", id: "http_request"}], "HTTP Request")
      {"HTTP Request 2", "http_request_2"}
  """
  @spec generate_unique_step_identity([map()], String.t()) :: {String.t(), String.t()}
  def generate_unique_step_identity(existing_steps, base_name) do
    existing_names =
      existing_steps
      |> Enum.map(&(Map.get(&1, :name) || Map.get(&1, "name")))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    existing_ids =
      existing_steps
      |> Enum.map(&(Map.get(&1, :id) || Map.get(&1, "id")))
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    do_generate_unique_identity(existing_names, existing_ids, base_name, 1)
  end

  defp do_generate_unique_identity(existing_names, existing_ids, base_name, index) do
    candidate_name = if index == 1, do: base_name, else: "#{base_name} #{index}"
    candidate_id = to_step_id(candidate_name)

    cond do
      MapSet.member?(existing_names, candidate_name) ->
        do_generate_unique_identity(existing_names, existing_ids, base_name, index + 1)

      MapSet.member?(existing_ids, candidate_id) ->
        do_generate_unique_identity(existing_names, existing_ids, base_name, index + 1)

      true ->
        {candidate_name, candidate_id}
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp insert_duplicate_draft(workflow_id, draft) do
    draft_attrs = %{
      steps: Enum.map(List.wrap(draft.steps), &Map.from_struct/1),
      connections: Enum.map(List.wrap(draft.connections), &Map.from_struct/1),
      groups: Enum.map(List.wrap(draft.groups), &Map.from_struct/1),
      settings: draft.settings || %{}
    }

    %WorkflowDraft{workflow_id: workflow_id}
    |> WorkflowDraft.changeset(draft_attrs)
    |> Repo.insert()
  end

  defp ensure_draft_defaults(nil), do: nil

  defp ensure_draft_defaults(draft) do
    %{
      draft
      | steps: draft.steps || [],
        connections: draft.connections || [],
        groups: draft.groups || []
    }
  end
end
