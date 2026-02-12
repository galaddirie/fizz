# Example: Get Network Policy
# Endpoint: GET /v1/sprites/{name}/policy/network

token = System.get_env("SPRITE_TOKEN")
sprite_name = System.get_env("SPRITE_NAME")

client = Sprites.new(token)
sprite = Sprites.sprite(client, sprite_name)

{:ok, policy} = Sprites.get_network_policy(sprite)

policy
|> Sprites.Policy.to_map()
|> Jason.encode!(pretty: true)
|> IO.puts()
