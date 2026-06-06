defmodule Fizz.Workflows.Compiler.Hasher do
  @moduledoc false

  @spec hash(map()) :: String.t()
  def hash(ir) when is_map(ir) do
    payload = %{
      "steps" =>
        ir.steps
        |> Map.values()
        |> Enum.map(fn step ->
          %{
            "id" => step.id,
            "type_id" => step.type_id,
            "config" => step.config
          }
        end)
        |> Enum.sort_by(& &1["id"]),
      "connections" =>
        ir.connections
        |> Enum.map(fn connection ->
          %{
            "id" => connection.id,
            "source_step_id" => connection.source_step_id,
            "source_output" => connection.source_output,
            "target_step_id" => connection.target_step_id,
            "target_input" => connection.target_input
          }
        end)
        |> Enum.sort_by(& &1["id"])
    }

    payload
    |> encode_canonical_json()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp encode_canonical_json(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> encode_canonical_json()
  end

  defp encode_canonical_json(map) when is_map(map) do
    contents =
      map
      |> Enum.map(fn {key, value} -> {normalize_json_key(key), encode_canonical_json(value)} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join(",", fn {key, value} -> Jason.encode!(key) <> ":" <> value end)

    "{#{contents}}"
  end

  defp encode_canonical_json(list) when is_list(list) do
    "[#{Enum.map_join(list, ",", &encode_canonical_json/1)}]"
  end

  defp encode_canonical_json(value), do: Jason.encode!(value)

  defp normalize_json_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_json_key(key) when is_binary(key), do: key
  defp normalize_json_key(key), do: inspect(key)
end
