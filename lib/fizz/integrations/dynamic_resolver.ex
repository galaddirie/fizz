defmodule Fizz.Integrations.DynamicResolver do
  @moduledoc """
  Dispatches schema-declared dynamic field resolvers for the workflow editor.

  The editor supplies the current draft, client payload, and request context.
  This module owns field schema lookup, resolver discovery, schema/payload param
  merging, and metadata returned to generic Vue field components.
  """

  alias Fizz.Credentials.OptionsResolver
  alias Fizz.Steps
  alias Fizz.Steps.Type
  alias Fizz.Workflows.Embeds.Step
  alias Fizz.Workflows.WorkflowDefinitionVersion

  @type result :: %{
          resolver: module(),
          options: [map()],
          meta: map()
        }

  @spec resolve(WorkflowDefinitionVersion.t(), map(), map(), keyword()) ::
          {:ok, result()} | {:error, term()}
  def resolve(%WorkflowDefinitionVersion{} = draft, payload, context, _opts)
      when is_map(payload) and is_map(context) do
    with {:ok, step_id} <- resolver_step_id(payload),
         {:ok, field_key} <- resolver_field_key(payload),
         {:ok, step} <- fetch_step(draft, step_id),
         {:ok, type} <- Steps.get_type(step.type_id),
         {:ok, field_schema} <- fetch_config_field_schema(type, field_key),
         {:ok, resolver} <- fetch_field_resolver(field_schema),
         params <- merge_resolver_params(field_schema, payload),
         {:ok, options} <-
           resolver.resolve(%{
             q: resolver_query(payload),
             params: params,
             context: context
           }) do
      {:ok,
       %{
         resolver: resolver,
         options: options,
         meta: resolver_meta(field_schema, params)
       }}
    end
  end

  def resolve(%WorkflowDefinitionVersion{}, _payload, _context, _opts),
    do: {:error, :invalid_resolver_payload}

  def resolve(_draft, _payload, _context, _opts), do: {:error, :draft_not_loaded}

  defp resolver_step_id(payload) do
    case Map.get(payload, "node_id") || Map.get(payload, :node_id) ||
           Map.get(payload, "step_id") || Map.get(payload, :step_id) do
      step_id when is_binary(step_id) -> {:ok, step_id}
      _ -> {:error, :step_id_required}
    end
  end

  defp resolver_field_key(payload) do
    case Map.get(payload, "field_key") || Map.get(payload, :field_key) do
      field_key when is_binary(field_key) -> {:ok, field_key}
      _ -> {:error, :field_key_required}
    end
  end

  defp fetch_step(%WorkflowDefinitionVersion{} = draft, step_id) do
    case Enum.find(draft.steps, &(&1.id == step_id)) do
      %Step{} = step -> {:ok, step}
      nil -> {:error, :step_not_found}
    end
  end

  defp fetch_config_field_schema(%Type{} = type, field_key) do
    case get_in(type.config_schema, ["properties", field_key]) do
      field_schema when is_map(field_schema) -> {:ok, field_schema}
      _ -> {:error, :field_not_found}
    end
  end

  defp fetch_field_resolver(field_schema) do
    case field_ui_value(field_schema, :resolver) do
      resolver when is_atom(resolver) and not is_nil(resolver) ->
        ensure_resolver_loaded(resolver)

      _ ->
        fetch_credential_field_resolver(field_schema)
    end
  end

  defp ensure_resolver_loaded(resolver) do
    case Code.ensure_loaded(resolver) do
      {:module, _module} ->
        case function_exported?(resolver, :resolve, 1) do
          true -> {:ok, resolver}
          false -> {:error, :resolver_not_found}
        end

      _ ->
        {:error, :resolver_not_found}
    end
  end

  defp fetch_credential_field_resolver(field_schema) do
    case field_ui_value(field_schema, :component) do
      "credential" -> {:ok, OptionsResolver}
      _ -> {:error, :resolver_not_found}
    end
  end

  defp merge_resolver_params(field_schema, payload) do
    payload
    |> payload_resolver_params()
    |> Map.merge(schema_resolver_params(field_schema))
  end

  defp schema_resolver_params(field_schema) do
    field_schema
    |> credential_field_resolver_params()
    |> Map.merge(resolver_ui_params(field_schema))
  end

  defp credential_field_resolver_params(field_schema) do
    case field_ui_value(field_schema, :component) do
      "credential" ->
        %{}
        |> maybe_put("provider_filter", field_ui_value(field_schema, :provider))
        |> maybe_put("auth_types", field_ui_value(field_schema, :auth_type))

      _ ->
        %{}
    end
  end

  defp resolver_ui_params(field_schema) do
    case field_ui_value(field_schema, :params) do
      params when is_map(params) -> params
      _ -> %{}
    end
  end

  defp payload_resolver_params(payload) do
    params =
      case Map.get(payload, "params") || Map.get(payload, :params) do
        params when is_map(params) -> params
        _ -> %{}
      end

    params
    |> maybe_put(
      "provider_filter",
      Map.get(payload, "provider_filter") || Map.get(payload, :provider_filter)
    )
    |> maybe_put("auth_types", Map.get(payload, "auth_types") || Map.get(payload, :auth_types))
  end

  defp resolver_query(payload) do
    case Map.get(payload, "q") || Map.get(payload, :q) do
      query when is_binary(query) -> query
      _ -> ""
    end
  end

  defp resolver_meta(field_schema, params) do
    %{}
    |> maybe_put(:depends_on, field_depends_on(field_schema))
    |> maybe_put(:display, schema_extension(field_schema, "display"))
    |> maybe_put(:resource_locator, schema_extension(field_schema, "resource_locator"))
    |> maybe_put(:resource_mapper, schema_extension(field_schema, "resource_mapper"))
    |> maybe_put(:params, params)
  end

  defp field_depends_on(field_schema) do
    case schema_extension(field_schema, "depends_on") do
      depends_on when is_list(depends_on) -> depends_on
      _ -> nil
    end
  end

  defp schema_extension(field_schema, key) when is_map(field_schema) do
    Map.get(field_schema, key) || get_in(field_schema, ["ui", key])
  end

  defp schema_extension(_field_schema, _key), do: nil

  defp field_ui_value(field_schema, key) when is_map(field_schema) and is_atom(key) do
    ui = Map.get(field_schema, "ui") || Map.get(field_schema, :ui) || %{}
    Map.get(ui, Atom.to_string(key)) || Map.get(ui, key)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
