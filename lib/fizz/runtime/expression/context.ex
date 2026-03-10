defmodule Fizz.Runtime.Expression.Context do
  @moduledoc """
  Builds the variable context for expression evaluation.

  Transforms a runtime metadata map into a flat map suitable for Liquid template
  rendering.

  ## Variable Structure

  ```
  %{
    "json" => current_input,
    "steps" => %{
      "StepName" => %{"json" => output_data, ...},
      ...
    },
    "execution" => %{
      "id" => "uuid",
      "started_at" => datetime,
      ...
    },
    "workflow" => %{
      "id" => "uuid"
    },
    "variables" => %{...workflow variables...},
    "metadata" => %{...runtime metadata...},
    "request" => %{
      "user_id" => "uuid",
      "request_id" => "uuid",
      "headers" => %{...},
      "body" => %{...},
      "params" => %{...}
    },
    "env" => %{...allowed env vars...}
  }
  ```
  """

  # Environment variables that are safe to expose
  # Configure via application env: config :fizz, :allowed_env_vars, [...]
  @default_allowed_env_vars ~w(
    MIX_ENV
    STEP_ENV
    APP_ENV
  )

  @doc """
  Builds a variable map from runtime metadata and step outputs.

  The resulting map uses string keys for compatibility with Liquid.

  ## Parameters

  - `ctx` - Runtime metadata map
  - `step_outputs` - Map of step_id -> output data
  - `current_input` - The input data for the current step (optional)
  """
  @spec build(map(), term(), term()) :: map()
  def build(ctx, step_outputs \\ %{}, current_input \\ nil)

  def build(ctx, step_outputs, current_input) when is_map(ctx) do
    input =
      current_input ||
        read_context_field(ctx, :input) ||
        read_context_field(ctx, :trigger)

    base_step_outputs = read_context_field(ctx, :step_outputs, %{})
    runtime_step_outputs = if is_map(step_outputs), do: step_outputs, else: %{}
    trigger = read_context_field(ctx, :trigger)
    trigger_type = read_context_field(ctx, :trigger_type) || "unknown"
    execution_id = read_context_field(ctx, :execution_id)
    workflow_id = read_context_field(ctx, :workflow_id)
    variables = read_context_field(ctx, :variables, %{})
    metadata = read_context_field(ctx, :metadata, %{})
    request = read_context_field(ctx, :request, %{})
    metadata = normalize_map(metadata)
    request = normalize_map(request)

    %{
      "json" => normalize_value(input),
      "input" => normalize_value(input),
      "steps" =>
        build_steps_map(Map.merge(normalize_map(base_step_outputs), runtime_step_outputs)),
      "execution" => %{
        "id" => execution_id,
        "trigger_type" => to_string(trigger_type),
        "trigger_data" => normalize_value(trigger)
      },
      "workflow" => %{
        "id" => workflow_id
      },
      "variables" => normalize_map(variables),
      "metadata" => metadata,
      "request" => request,
      "trigger" => normalize_value(trigger),
      "env" => build_env_map(),
      "now" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "today" => Date.utc_today() |> Date.to_iso8601()
    }
    |> put_execution_metadata(metadata)
  end

  def build(_ctx, _step_outputs, current_input), do: build_minimal(current_input || %{})

  @doc """
  Builds a variable map from runtime metadata.
  """
  def build_from_context(ctx) when is_map(ctx) do
    build(ctx)
  end

  def build_from_context(_ctx), do: build_minimal()

  @doc """
  Builds a minimal context for testing or simple evaluations.
  """
  @spec build_minimal(map()) :: map()
  def build_minimal(input \\ %{}) do
    %{
      "json" => normalize_value(input),
      "input" => normalize_value(input),
      "steps" => %{},
      "execution" => %{},
      "workflow" => %{},
      "variables" => %{},
      "metadata" => %{},
      "request" => %{},
      "env" => build_env_map(),
      "now" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "today" => Date.utc_today() |> Date.to_iso8601()
    }
  end

  # ============================================================================
  # Private Builders
  # ============================================================================

  defp build_steps_map(step_outputs) when is_map(step_outputs) do
    Map.new(step_outputs, fn {step_id, output} ->
      step_data = %{
        "json" => normalize_value(output),
        "data" => normalize_value(output)
      }

      # Also extract common fields for convenience
      step_data =
        if is_map(output) do
          step_data
          |> maybe_put("status", output["status"] || output[:status])
          |> maybe_put("body", output["body"] || output[:body])
          |> maybe_put("headers", output["headers"] || output[:headers])
          |> maybe_put("error", output["error"] || output[:error])
        else
          step_data
        end

      {step_id, step_data}
    end)
  end

  defp build_steps_map(_), do: %{}

  defp build_env_map do
    allowed_vars()
    |> Enum.reduce(%{}, fn var, acc ->
      case System.get_env(var) do
        nil -> acc
        value -> Map.put(acc, var, value)
      end
    end)
  end

  defp allowed_vars do
    Application.get_env(:fizz, :allowed_env_vars, @default_allowed_env_vars)
  end

  defp get_metadata_field(%{} = metadata, key) when is_atom(key) do
    Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))
  end

  defp get_metadata_field(_, _), do: nil

  defp put_execution_metadata(%{"execution" => execution} = vars, metadata) do
    execution =
      execution
      |> maybe_put("trace_id", get_metadata_field(metadata, :trace_id))
      |> maybe_put("correlation_id", get_metadata_field(metadata, :correlation_id))

    put_in(vars, ["execution"], execution)
  end

  # ============================================================================
  # Value Normalization
  # ============================================================================

  @doc """
  Normalizes a value for use in Liquid templates.

  - Converts structs to maps
  - Ensures string keys
  - Handles DateTime/Date conversion
  - Preserves primitives
  """
  @spec normalize_value(term()) :: term()
  def normalize_value(value) when is_struct(value, DateTime) do
    DateTime.to_iso8601(value)
  end

  def normalize_value(value) when is_struct(value, NaiveDateTime) do
    NaiveDateTime.to_iso8601(value)
  end

  def normalize_value(value) when is_struct(value, Date) do
    Date.to_iso8601(value)
  end

  def normalize_value(value) when is_struct(value, Time) do
    Time.to_iso8601(value)
  end

  def normalize_value(%{__struct__: _} = value) do
    value
    |> Map.from_struct()
    |> Map.drop([:__meta__])
    |> normalize_map()
  end

  def normalize_value(%{"value" => v}) when map_size(%{"value" => v}) == 1 do
    normalize_value(v)
  end

  def normalize_value(value) when is_map(value) do
    normalize_map(value)
  end

  def normalize_value(value) when is_list(value) do
    # Filter nils and collapse if only one result exists (common in joins)
    case Enum.reject(value, &is_nil/1) do
      [single] -> normalize_value(single)
      filtered -> Enum.map(filtered, &normalize_value/1)
    end
  end

  def normalize_value(value)
      when is_atom(value) and not is_boolean(value) and not is_nil(value) do
    Atom.to_string(value)
  end

  def normalize_value(value), do: value

  defp read_context_field(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp normalize_map(map) when is_map(map) do
    Map.new(map, fn {k, v} ->
      key = if is_atom(k), do: Atom.to_string(k), else: to_string(k)
      {key, normalize_value(v)}
    end)
  end

  defp normalize_map(_), do: %{}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, normalize_value(value))
end
