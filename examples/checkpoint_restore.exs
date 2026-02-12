# Example: Restore Checkpoint
# Endpoint: POST /v1/sprites/{name}/checkpoints/{checkpoint_id}/restore

token = System.get_env("SPRITE_TOKEN")
sprite_name = System.get_env("SPRITE_NAME")
checkpoint_id = System.get_env("CHECKPOINT_ID") || "v1"

client = Sprites.new(token)
sprite = Sprites.sprite(client, sprite_name)

{:ok, messages} = Sprites.restore_checkpoint(sprite, checkpoint_id)

Enum.each(messages, fn msg ->
  IO.puts(Jason.encode!(Sprites.StreamMessage.to_map(msg)))
end)
