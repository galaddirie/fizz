defmodule Fizz.Triggers.Webhook do
  @moduledoc """
  Helpers for webhook path generation and HMAC verification.
  """

  @algorithm_digests %{
    "hmac-sha256" => :sha256,
    "sha256" => :sha256,
    "hmac-sha1" => :sha1,
    "sha1" => :sha1
  }

  @spec generate_path() :: String.t()
  def generate_path do
    "wh_" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
  end

  @spec generate_secret() :: String.t()
  def generate_secret do
    :crypto.strong_rand_bytes(32)
    |> Base.encode64()
  end

  @spec verify_signature(binary(), binary(), binary(), binary()) :: boolean()
  def verify_signature(payload_body, secret, signature_header_value, algorithm \\ "hmac-sha256")
      when is_binary(payload_body) and is_binary(secret) and is_binary(signature_header_value) and
             is_binary(algorithm) do
    with {:ok, digest_algorithm} <- fetch_digest_algorithm(algorithm) do
      expected_signature =
        :crypto.mac(:hmac, digest_algorithm, secret, payload_body)
        |> Base.encode16(case: :lower)

      signature_header_value
      |> extract_signatures()
      |> Enum.any?(&secure_compare?(expected_signature, &1))
    else
      {:error, _reason} -> false
    end
  end

  defp fetch_digest_algorithm(algorithm) do
    case Map.get(@algorithm_digests, String.downcase(algorithm)) do
      nil -> {:error, :unsupported_algorithm}
      digest -> {:ok, digest}
    end
  end

  defp extract_signatures(signature_header_value) do
    signature_header_value
    |> String.split(",", trim: true)
    |> Enum.flat_map(fn part ->
      value = String.trim(part)

      cond do
        String.contains?(value, "=") ->
          [_prefix, signature] = String.split(value, "=", parts: 2)
          [value, String.trim(signature) |> String.downcase()]

        true ->
          [String.downcase(value)]
      end
    end)
    |> Enum.uniq()
  end

  defp secure_compare?(expected_signature, provided_signature)
       when byte_size(expected_signature) == byte_size(provided_signature) do
    Plug.Crypto.secure_compare(expected_signature, provided_signature)
  end

  defp secure_compare?(_expected_signature, _provided_signature), do: false
end
