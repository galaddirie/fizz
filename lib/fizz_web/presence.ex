defmodule FizzWeb.Presence do
  use Phoenix.Presence,
    otp_app: :fizz,
    pubsub_server: Fizz.PubSub
end
