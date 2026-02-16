defmodule Fizz.SpritesTest do
  use Fizz.DataCase, async: true

  alias Fizz.Sprites

  test "list_sprites/2 returns unauthenticated when scope is nil" do
    assert {:error, :unauthenticated} = Sprites.list_sprites(nil, Ecto.UUID.generate())
  end

  test "create_sprite/3 returns unauthenticated when scope is nil" do
    assert {:error, :unauthenticated} =
             Sprites.create_sprite(nil, Ecto.UUID.generate(), %{"name" => "demo"})
  end

  test "enqueue_job/4 returns unauthenticated when scope is nil" do
    assert {:error, :unauthenticated} =
             Sprites.enqueue_job(nil, Ecto.UUID.generate(), Ecto.UUID.generate(), %{
               "command" => "echo hi"
             })
  end
end
