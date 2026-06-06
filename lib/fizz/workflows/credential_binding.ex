defmodule Fizz.Workflows.CredentialBinding do
  @moduledoc """
  Per-user credential choice for a workflow step requirement.

  A credential binding stores the concrete value a particular user has chosen for a
  declared credential requirement in a workflow step. Bindings are keyed by
  user, workflow definition, step, and
  requirement key, and are scoped to the long-lived `workflow_definition_id` so that
  re-publishing a workflow does not invalidate user bindings.
  """

  use Fizz.Schema

  alias Fizz.Workflows.WorkflowDefinition

  @type t :: %__MODULE__{}

  schema "credential_bindings" do
    field :user_id, :string
    field :step_id, :string
    field :requirement_key, :string
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
      :requirement_key,
      :binding_data,
      :workos_organization_id
    ])
    |> validate_required([
      :user_id,
      :workflow_definition_id,
      :step_id,
      :requirement_key,
      :binding_data,
      :workos_organization_id
    ])
    |> validate_length(:user_id, min: 1, max: 255)
    |> validate_length(:step_id, min: 1, max: 255)
    |> validate_length(:requirement_key, min: 1, max: 64)
    |> validate_length(:workos_organization_id, min: 3, max: 120)
    |> validate_binding_data()
    |> foreign_key_constraint(:workflow_definition_id)
    |> unique_constraint([:user_id, :workflow_definition_id, :step_id, :requirement_key],
      name: :credential_bindings_user_definition_step_requirement_index
    )
  end

  defp validate_binding_data(%Ecto.Changeset{valid?: false} = changeset), do: changeset

  defp validate_binding_data(changeset) do
    binding_data = get_field(changeset, :binding_data)

    case binding_data do
      %{"credential_id" => credential_id} when is_binary(credential_id) ->
        if String.trim(credential_id) == "" do
          add_error(changeset, :binding_data, "credential_id_required")
        else
          changeset
        end

      _ ->
        add_error(changeset, :binding_data, "credential_id_required")
    end
  end
end
