defmodule Fizz.Workflows.SlotBinding do
  @moduledoc """
  Per-user resolution of a workflow step slot.

  A slot binding stores the concrete value a particular user has chosen for a
  declared slot in a workflow step (e.g. which credential of theirs to use for
  the auth slot). Bindings are keyed by user, workflow definition, step, and
  slot key, and are scoped to the long-lived `workflow_definition_id` so that
  re-publishing a workflow does not invalidate user bindings.
  """

  use Fizz.Schema

  alias Fizz.Slots.Registry
  alias Fizz.Workflows.WorkflowDefinition

  @type t :: %__MODULE__{}

  schema "slot_bindings" do
    field :user_id, :string
    field :step_id, :string
    field :slot_key, :string
    field :kind, :string
    field :binding_data, :map, default: %{}
    field :workos_organization_id, :string

    belongs_to :workflow_definition, WorkflowDefinition

    timestamps()
  end

  @doc false
  def changeset(binding, attrs) do
    binding
    |> cast(attrs, [
      :user_id,
      :workflow_definition_id,
      :step_id,
      :slot_key,
      :kind,
      :binding_data,
      :workos_organization_id
    ])
    |> validate_required([
      :user_id,
      :workflow_definition_id,
      :step_id,
      :slot_key,
      :kind,
      :binding_data,
      :workos_organization_id
    ])
    |> validate_length(:user_id, min: 1, max: 255)
    |> validate_length(:step_id, min: 1, max: 255)
    |> validate_length(:slot_key, min: 1, max: 64)
    |> validate_length(:workos_organization_id, min: 3, max: 120)
    |> validate_kind_registered()
    |> validate_binding_data_for_kind()
    |> foreign_key_constraint(:workflow_definition_id)
    |> unique_constraint([:user_id, :workflow_definition_id, :step_id, :slot_key],
      name: :slot_bindings_user_definition_step_slot_index
    )
  end

  defp validate_kind_registered(changeset) do
    case get_field(changeset, :kind) do
      kind when is_binary(kind) ->
        case Registry.fetch(kind) do
          {:ok, _module} -> changeset
          :error -> add_error(changeset, :kind, "is not a registered slot kind")
        end

      _ ->
        changeset
    end
  end

  defp validate_binding_data_for_kind(%Ecto.Changeset{valid?: false} = changeset), do: changeset

  defp validate_binding_data_for_kind(changeset) do
    kind = get_field(changeset, :kind)
    binding_data = get_field(changeset, :binding_data)

    with {:ok, module} <- Registry.fetch(kind),
         :ok <- module.validate_binding_data(binding_data) do
      changeset
    else
      :error ->
        changeset

      {:error, reason} ->
        add_error(changeset, :binding_data, format_reason(reason))
    end
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
