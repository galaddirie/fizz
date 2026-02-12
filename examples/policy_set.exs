# Example: Set Network Policy
# Endpoint: POST /v1/sprites/{name}/policy/network

token = System.get_env("SPRITE_TOKEN")
sprite_name = System.get_env("SPRITE_NAME")

client = Sprites.new(token)
sprite = Sprites.sprite(client, sprite_name)

policy = %Sprites.Policy{
  rules: [
    %Sprites.Policy.Rule{domain: "api.github.com", action: "allow"},
    %Sprites.Policy.Rule{domain: "*.npmjs.org", action: "allow"}
  ]
}

:ok = Sprites.update_network_policy(sprite, policy)

IO.puts("Network policy updated")
