# Example: Update Sprite
# Endpoint: PUT /v1/sprites/{name}

token = System.get_env("SPRITE_TOKEN")
sprite_name = System.get_env("SPRITE_NAME")

client = Sprites.new(token)
sprite = Sprites.sprite(client, sprite_name)

:ok = Sprites.update_url_settings(sprite, %{auth: "public"})

IO.puts("URL settings updated")
