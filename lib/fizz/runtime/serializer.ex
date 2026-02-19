defmodule Fizz.Runtime.Serializer do
  @moduledoc """
  Shared helpers for converting runtime values into JSON-safe terms.
  """

  @type atom_mode :: :string | :preserve_boolean_and_nil

  @doc """
  Recursively sanitizes a value for JSON storage/logging.

  - Converts map keys to strings
  - Converts structs to maps
  - Inspects refs, ports, pids, and functions
  """
  @spec sanitize(term(), atom_mode()) :: term()
  def sanitize(value, atom_mode \\ :string) do
    do_sanitize(value, atom_mode)
  end

  @doc """
  Wraps a value for :map database fields, preserving booleans and nils.
  """
  @spec wrap_for_db(term()) :: map() | nil
  def wrap_for_db(nil), do: nil

  def wrap_for_db(%_struct{} = value) do
    value
    |> Map.from_struct()
    |> wrap_for_db()
  end

  def wrap_for_db(value) when is_map(value) do
    sanitize(value, :preserve_boolean_and_nil)
  end

  def wrap_for_db(value) do
    %{"value" => sanitize(value, :preserve_boolean_and_nil)}
  end

  @doc """
  Sanitizes a value for PubSub broadcasting.
  Uses the same wrapping logic as wrap_for_db to ensure UI consistency.
  """
  def sanitize_for_broadcast(value) do
    wrap_for_db(value)
  end

  defp do_sanitize(value, atom_mode) when is_atom(value) do
    case atom_mode do
      :string ->
        Atom.to_string(value)

      :preserve_boolean_and_nil ->
        if value in [true, false, nil], do: value, else: Atom.to_string(value)
    end
  end

  defp do_sanitize(value, atom_mode) when is_struct(value) do
    value
    |> Map.from_struct()
    |> do_sanitize(atom_mode)
  end

  defp do_sanitize(value, atom_mode) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> do_sanitize(atom_mode)
  end

  defp do_sanitize(value, atom_mode) when is_map(value) do
    Map.new(value, fn {k, v} -> {sanitize_key(k), do_sanitize(v, atom_mode)} end)
  end

  defp do_sanitize(value, atom_mode) when is_list(value) do
    Enum.map(value, &do_sanitize(&1, atom_mode))
  end

  defp do_sanitize(value, _atom_mode)
       when is_pid(value) or is_port(value) or is_reference(value),
       do: inspect(value)

  defp do_sanitize(value, _atom_mode) when is_function(value), do: inspect(value)
  defp do_sanitize(value, _atom_mode), do: value

  defp sanitize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp sanitize_key(key) when is_binary(key), do: key
  defp sanitize_key(key), do: inspect(key)
end
