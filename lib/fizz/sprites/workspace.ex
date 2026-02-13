defmodule Fizz.Sprites.Workspace do
  @moduledoc """
  Resolved workspace identity for a tenant-specific sprite.
  """

  alias Fizz.Sprites.Name

  @enforce_keys [:workspace_id, :tenant_id, :workspace_key, :sprite_name, :tenant_prefix]
  defstruct [:workspace_id, :tenant_id, :workspace_key, :sprite_name, :tenant_prefix]

  @type t :: %__MODULE__{
          workspace_id: String.t(),
          tenant_id: String.t(),
          workspace_key: String.t(),
          sprite_name: String.t(),
          tenant_prefix: String.t()
        }

  @spec new(String.t(), String.t()) :: t()
  def new(tenant_id, workspace_key) do
    normalized_workspace_key = Name.normalize_workspace_key(workspace_key)

    %__MODULE__{
      workspace_id: Name.workspace_id(tenant_id, normalized_workspace_key),
      tenant_id: tenant_id,
      workspace_key: normalized_workspace_key,
      sprite_name: Name.sprite_name(tenant_id, normalized_workspace_key),
      tenant_prefix: Name.tenant_prefix(tenant_id)
    }
  end
end
