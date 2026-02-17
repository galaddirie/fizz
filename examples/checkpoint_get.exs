# Example: Get Checkpoint
# Endpoint: GET /v1/sprites/{name}/checkpoints/{checkpoint_id}

token = System.get_env("SPRITE_TOKEN")
sprite_name = System.get_env("SPRITE_NAME")
checkpoint_id = System.get_env("CHECKPOINT_ID") || "v1"

client = Sprites.new(token)
sprite = Sprites.sprite(client, sprite_name)

{:ok, checkpoint} = Sprites.get_checkpoint(sprite, checkpoint_id)

checkpoint
|> Map.from_struct()
|> Map.update(:create_time, nil, fn
  nil -> nil
  dt -> DateTime.to_iso8601(dt)
end)
|> Map.reject(fn {_k, v} -> is_nil(v) end)
|> Jason.encode!(pretty: true)
|> IO.puts()
