defmodule Fizz.Integrations.Library.OpenAI.ChatModelProvider do
  @moduledoc false

  @behaviour Fizz.Integrations.Library.Fizz.Builtins.ChatModelProviders.Provider

  alias Fizz.Accounts.Scope
  alias Fizz.Integrations.Library.OpenAI.Client

  @impl true
  def provider_prefix, do: "openai"

  @impl true
  def generate(%{"model" => model, "structured_schema" => structured_schema} = request, context)
      when is_map(structured_schema) do
    with {:ok, scope, organization_id} <- scope_and_organization(context),
         {:ok, schema} <- fetch_structured_schema(structured_schema),
         {:ok, response} <-
           Client.generate_object(
             scope,
             organization_id,
             model["model_spec"],
             request["messages"],
             schema,
             generation_opts(model)
           )
           |> normalize_provider_error(model["model_spec"]) do
      {:ok, response}
    end
  end

  def generate(%{"model" => model} = request, context) do
    with {:ok, scope, organization_id} <- scope_and_organization(context),
         {:ok, response} <-
           Client.generate_text(
             scope,
             organization_id,
             model["model_spec"],
             request["messages"],
             generation_opts(model)
           )
           |> normalize_provider_error(model["model_spec"]) do
      {:ok, response}
    end
  end

  defp fetch_structured_schema(%{"schema" => schema}) when is_map(schema), do: {:ok, schema}
  defp fetch_structured_schema(_structured_schema), do: {:error, :missing_structured_schema}

  defp normalize_provider_error({:error, :not_found}, model_spec) when is_binary(model_spec) do
    {:error, {:model_not_found, model_spec}}
  end

  defp normalize_provider_error(result, _model_spec), do: result

  defp generation_opts(model) do
    []
    |> maybe_put_opt(:temperature, model["temperature"])
    |> maybe_put_opt(:max_tokens, model["max_tokens"])
    |> maybe_put_opt(:credential_ref, model["credential_ref"])
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp scope_and_organization(ctx) when is_map(ctx) do
    with {:ok, scope} <- scope_from_context(ctx),
         {:ok, organization_id} <- organization_from_scope(scope) do
      {:ok, scope, organization_id}
    end
  end

  defp scope_and_organization(_ctx), do: {:error, :scope_not_available}

  defp scope_from_context(ctx) when is_map(ctx) do
    metadata = Map.get(ctx, :metadata) || Map.get(ctx, "metadata")

    scope =
      Map.get(ctx, :scope) ||
        Map.get(ctx, "scope") ||
        Map.get(ctx, :current_scope) ||
        Map.get(ctx, "current_scope") ||
        if(is_map(metadata), do: Map.get(metadata, :scope) || Map.get(metadata, "scope"))

    case scope do
      %Scope{} = scope -> {:ok, scope}
      _ -> {:error, :scope_not_available}
    end
  end

  defp scope_from_context(_ctx), do: {:error, :scope_not_available}

  defp organization_from_scope(%Scope{organization_id: organization_id})
       when is_binary(organization_id) and byte_size(organization_id) > 0,
       do: {:ok, organization_id}

  defp organization_from_scope(%Scope{project: %{workos_organization_id: organization_id}})
       when is_binary(organization_id) and byte_size(organization_id) > 0,
       do: {:ok, organization_id}

  defp organization_from_scope(%Scope{}), do: {:error, :organization_scope_required}
end
