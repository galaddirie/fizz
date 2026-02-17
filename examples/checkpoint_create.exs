# Example: Create Checkpoint
# Endpoint: POST /v1/sprites/{name}/checkpoint

token = System.get_env("SPRITE_TOKEN")
sprite_name = System.get_env("SPRITE_NAME")

client = Sprites.new(token)
sprite = Sprites.sprite(client, sprite_name)

{:ok, messages} = Sprites.create_checkpoint(sprite, comment: "my-checkpoint")

Enum.each(messages, fn msg ->
  IO.puts(Jason.encode!(Sprites.StreamMessage.to_map(msg)))
end)
