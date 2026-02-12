# Example: List Checkpoints
# Endpoint: GET /v1/sprites/{name}/checkpoints

token = System.get_env("SPRITE_TOKEN")
sprite_name = System.get_env("SPRITE_NAME")

client = Sprites.new(token)
sprite = Sprites.sprite(client, sprite_name)

{:ok, checkpoints} = Sprites.list_checkpoints(sprite)

checkpoints
|> Enum.map(fn cp ->
  cp
  |> Map.from_struct()
  |> Map.update(:create_time, nil, fn
    nil -> nil
    dt -> DateTime.to_iso8601(dt)
  end)
  |> Map.reject(fn {_k, v} -> is_nil(v) end)
end)
|> Jason.encode!(pretty: true)
|> IO.puts()
