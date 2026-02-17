# Example: Quick Start
# Endpoint: quickstart

# step: Install
# mix deps.get

# step: Setup client
client = Sprites.new(System.get_env("SPRITE_TOKEN"))

# step: Create a sprite
Sprites.create(client, System.get_env("SPRITE_NAME"))

# step: Run Python
{output, _} = Sprites.cmd(Sprites.sprite(client, System.get_env("SPRITE_NAME")), "python", ["-c", "print(2+2)"])
IO.write(output)

# step: Clean up
Sprites.destroy(Sprites.sprite(client, System.get_env("SPRITE_NAME")))
