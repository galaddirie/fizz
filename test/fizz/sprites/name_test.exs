defmodule Fizz.Sprites.NameTest do
  use ExUnit.Case, async: true

  alias Fizz.Sprites.Name

  test "normalizes workspace keys" do
    assert Name.normalize_workspace_key("  My Workspace  ") == "my-workspace"
    assert Name.normalize_workspace_key("@@") == "default"
  end

  test "builds deterministic tenant prefixes and sprite names" do
    tenant_id = "org:org_123"
    workspace_key = "default"

    assert Name.tenant_prefix(tenant_id) == Name.tenant_prefix(tenant_id)

    assert Name.sprite_name(tenant_id, workspace_key) ==
             Name.sprite_name(tenant_id, workspace_key)
  end
end
