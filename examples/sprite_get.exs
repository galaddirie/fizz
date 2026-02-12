# Example: Get Sprite
# Endpoint: GET /v1/sprites/{name}

token = System.get_env("SPRITE_TOKEN")
sprite_name = System.get_env("SPRITE_NAME")

client = Sprites.new(token)

{:ok, sprite} = Sprites.get_sprite(client, sprite_name)

sprite
|> Jason.encode!(pretty: true)
|> IO.puts()
