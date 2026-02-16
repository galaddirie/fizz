defmodule Fizz.SpritesTest do
  use Fizz.DataCase, async: true

  alias Fizz.Sprites

  test "list_workspace_sprites/2 returns unauthenticated when scope is nil" do
    assert {:error, :unauthenticated} = Sprites.list_workspace_sprites(nil, Ecto.UUID.generate())
  end

  test "provision_sprite/3 returns unauthenticated when scope is nil" do
    assert {:error, :unauthenticated} =
             Sprites.provision_sprite(nil, Ecto.UUID.generate(), %{"name" => "demo"})
  end

  test "queue_job/4 returns unauthenticated when scope is nil" do
    assert {:error, :unauthenticated} =
             Sprites.queue_job(nil, Ecto.UUID.generate(), Ecto.UUID.generate(), %{
               "command" => "echo hi"
             })
  end
end
