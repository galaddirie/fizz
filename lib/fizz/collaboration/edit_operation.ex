defmodule Fizz.Collaboration.EditOperation do
  @moduledoc """
  Persisted edit operation for audit trail and recovery.
  """
  use Fizz.Schema

  @type op_type ::
          :add_step
          | :remove_step
          | :update_step_config
          | :update_step_position
          | :update_step_positions
          | :update_step_metadata
          | :add_connection
          | :remove_connection
          | :add_group
          | :update_group
          | :remove_group
          | :set_group_membership
          | :pin_step_output
          | :unpin_step_output
          | :disable_step
          | :enable_step

  schema "edit_operations" do
    field :operation_id, :string
    # Server-assigned sequence
    field :seq, :integer

    field :type, Ecto.Enum,
      values: [
        :add_step,
        :remove_step,
        :update_step_config,
        :update_step_position,
        :update_step_positions,
        :update_step_metadata,
        :add_connection,
        :remove_connection,
        :add_group,
        :update_group,
        :remove_group,
        :set_group_membership,
        :pin_step_output,
        :unpin_step_output,
        :disable_step,
        :enable_step
      ]

    field :payload, :map
    field :user_id, :binary_id
    field :client_seq, :integer

    belongs_to :workflow, Fizz.Workflows.Workflow

    timestamps(updated_at: false)
  end

  def changeset(op, attrs) do
    op
    |> cast(attrs, [:operation_id, :seq, :type, :payload, :user_id, :client_seq, :workflow_id])
    |> validate_required([:operation_id, :type, :payload, :workflow_id])
    |> unique_constraint(:operation_id)
    |> unique_constraint([:workflow_id, :seq])
  end
end
