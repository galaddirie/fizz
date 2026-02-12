defmodule Fizz.WorkOS.PKCE do
  @moduledoc """
  Helpers for AuthKit PKCE state/challenge generation.
  """

  @spec random_b64url(pos_integer()) :: String.t()
  def random_b64url(bytes \\ 32) when is_integer(bytes) and bytes > 0 do
    bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  @spec code_challenge_s256(String.t()) :: String.t()
  def code_challenge_s256(code_verifier) when is_binary(code_verifier) do
    :crypto.hash(:sha256, code_verifier)
    |> Base.url_encode64(padding: false)
  end
end
