defmodule Fizz.Triggers.WebhookTest do
  use ExUnit.Case, async: true

  alias Fizz.Triggers.Webhook

  test "generate_path/0 produces unique random tokens" do
    path_one = Webhook.generate_path()
    path_two = Webhook.generate_path()

    assert path_one != path_two
    assert String.starts_with?(path_one, "wh_")
    assert String.starts_with?(path_two, "wh_")
  end

  test "generate_secret/0 produces strong random values" do
    secret_one = Webhook.generate_secret()
    secret_two = Webhook.generate_secret()

    assert secret_one != secret_two
    assert byte_size(secret_one) >= 44
    assert byte_size(secret_two) >= 44
  end

  test "verify_signature/4 succeeds with the correct secret" do
    payload = ~s({"event":"push"})
    secret = "top-secret"

    signature =
      :crypto.mac(:hmac, :sha256, secret, payload)
      |> Base.encode16(case: :lower)
      |> then(&"sha256=#{&1}")

    assert Webhook.verify_signature(payload, secret, signature, "hmac-sha256")
  end

  test "verify_signature/4 fails with the wrong secret" do
    payload = ~s({"event":"push"})

    signature =
      :crypto.mac(:hmac, :sha256, "correct-secret", payload)
      |> Base.encode16(case: :lower)
      |> then(&"sha256=#{&1}")

    refute Webhook.verify_signature(payload, "wrong-secret", signature, "hmac-sha256")
  end

  test "verify_signature/4 handles direct hex signatures with timing-safe comparison" do
    payload = ~s({"event":"push"})
    secret = "another-secret"

    signature =
      :crypto.mac(:hmac, :sha256, secret, payload)
      |> Base.encode16(case: :lower)

    assert Webhook.verify_signature(payload, secret, signature, "sha256")
  end
end
