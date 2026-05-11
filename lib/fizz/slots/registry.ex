defmodule Fizz.Slots.Registry do
  @moduledoc """
  Lookup for slot kind resolver modules.

  The registry is configured at compile time via:

      config :fizz, Fizz.Slots, kinds: %{"credential" => Fizz.Slots.Resolvers.Credential}

  Reads from `Application.get_env/3` at call time so tests can override.
  """

  @spec fetch(String.t() | nil) :: {:ok, module()} | :error
  def fetch(kind) when is_binary(kind) do
    case Map.fetch(kinds(), kind) do
      {:ok, module} when is_atom(module) -> ensure_loaded(module)
      _ -> :error
    end
  end

  def fetch(_kind), do: :error

  @spec kinds() :: %{optional(String.t()) => module()}
  def kinds do
    :fizz
    |> Application.get_env(Fizz.Slots, [])
    |> Keyword.get(:kinds, %{})
  end

  defp ensure_loaded(module) do
    case Code.ensure_loaded(module) do
      {:module, ^module} -> {:ok, module}
      _ -> :error
    end
  end
end
