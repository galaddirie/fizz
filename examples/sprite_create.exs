# Example: Create Sprite
# Endpoint: POST /v1/sprites

token = System.get_env("SPRITE_TOKEN")
sprite_name = System.get_env("SPRITE_NAME")

client = Sprites.new(token)

{:ok, _sprite} = Sprites.create(client, sprite_name)

IO.puts("Sprite '#{sprite_name}' created")
