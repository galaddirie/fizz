# Example: Execute Command
# Endpoint: WSS /v1/sprites/{name}/exec

token = System.get_env("SPRITE_TOKEN")
sprite_name = System.get_env("SPRITE_NAME")

client = Sprites.new(token)
sprite = Sprites.sprite(client, sprite_name)

# Start a command that runs for 30s (TTY sessions stay alive after disconnect)
{:ok, cmd} = Sprites.spawn(sprite, "python", ["-c",
  "import time; print('Server ready on port 8080', flush=True); time.sleep(30)"],
  tty: true)  # TTY sessions are detachable

ref = cmd.ref

# Read for 2 seconds then exit (session keeps running)
receive do
  {:stdout, %{ref: ^ref}, data} ->
    IO.write(data)
after
  2000 -> :ok
end
