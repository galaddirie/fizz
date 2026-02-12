# Example: List Sprites
# Endpoint: GET /v1/sprites

token = System.get_env("SPRITE_TOKEN")

client = Sprites.new(token)

{:ok, sprites} = Sprites.list(client)

sprites
|> Jason.encode!(pretty: true)
|> IO.puts()
