defmodule Fizz.External.SpritesSmokeTest do
  use ExUnit.Case, async: false

  @moduletag :external_api
  @moduletag skip: System.get_env("SPRITES_API_KEY") in [nil, ""]

  test "lists sprites with optional prefix using real Sprites API" do
    api_key = System.fetch_env!("SPRITES_API_KEY")
    base_url = System.get_env("SPRITES_BASE_URL") || "https://api.sprites.dev"
    prefix = System.get_env("SPRITES_SMOKE_PREFIX") || ""

    client = Sprites.new(api_key, base_url: base_url)

    opts =
      if String.trim(prefix) == "" do
        []
      else
        [prefix: prefix]
      end

    assert {:ok, sprites} = Sprites.list(client, opts)
    assert is_list(sprites)
  end
end
