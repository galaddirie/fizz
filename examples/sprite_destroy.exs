# Example: Destroy Sprite
# Endpoint: DELETE /v1/sprites/{name}

token = System.get_env("SPRITE_TOKEN")
sprite_name = System.get_env("SPRITE_NAME")

client = Sprites.new(token)
sprite = Sprites.sprite(client, sprite_name)

:ok = Sprites.destroy(sprite)

IO.puts("Sprite '#{sprite_name}' destroyed")
