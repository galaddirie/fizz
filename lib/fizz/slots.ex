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
    * `upsert_binding/2` — create or update a binding
    * `delete_binding/4` — remove a binding
    * `bindings_for_run/1` — all bindings indexed for a run's actor + workflow
  """

  import Ecto.Query

  alias Fizz.Repo
  alias Fizz.Workflows.{SlotBinding, WorkflowRun}

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
  Creates or updates a slot binding by its composite key.

  Expects `attrs` to contain at least `user_id`, `workflow_definition_id`,
  `step_id`, `slot_key`, `kind`, `binding_data`, `workos_organization_id`.
  """
  @spec upsert_binding(map()) :: {:ok, SlotBinding.t()} | {:error, Ecto.Changeset.t()}
  def upsert_binding(attrs) when is_map(attrs) do
    attrs = atomize_keys(attrs)

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
  Deletes a binding by composite key. Returns `:ok` even if it didn't exist.
  """
  @spec delete_binding(String.t(), String.t(), String.t(), String.t()) :: :ok
  def delete_binding(workflow_definition_id, user_id, step_id, slot_key) do
    case get_binding(workflow_definition_id, user_id, step_id, slot_key) do
      nil -> :ok
      %SlotBinding{} = binding -> Repo.delete(binding) |> elem(0) |> case do
        :ok -> :ok
        _ -> :ok
      end
    end
  end

  @doc """
  Returns all bindings for the run's actor against the run's workflow,
  indexed by `{step_id, slot_key}` for fast lookup at runtime.
  """
  @spec bindings_for_run(WorkflowRun.t()) :: %{optional({String.t(), String.t()}) => SlotBinding.t()}
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

  defp atomize_keys(attrs) do
    Map.new(attrs, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  rescue
    ArgumentError -> attrs
  end
end
