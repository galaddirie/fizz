# Example: Attach to Session
# Endpoint: WSS /v1/sprites/{name}/exec/{session_id}

token = System.get_env("SPRITE_TOKEN")
sprite_name = System.get_env("SPRITE_NAME")

client = Sprites.new(token)
sprite = Sprites.sprite(client, sprite_name)

# Find the session from exec example
{:ok, sessions} = Sprites.list_sessions(sprite)
target_session = Enum.find(sessions, fn s ->
  String.contains?(s.command, "time.sleep") || String.contains?(s.command, "python")
end)

case target_session do
  nil ->
    IO.puts("No running session found")
    System.halt(1)

  session ->
    IO.puts("Attaching to session #{session.id}...")

    # Attach and read buffered output (includes data from before we connected)
    {:ok, cmd} = Sprites.attach_session(sprite, session.id)
    ref = cmd.ref

    # Read for 2 seconds then exit
    receive do
      {:stdout, %{ref: ^ref}, data} ->
        IO.write(data)
    after
      2000 -> :ok
    end
end
