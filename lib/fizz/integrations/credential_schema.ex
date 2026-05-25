defmodule Fizz.Integrations.CredentialSchema do
  @moduledoc """
  Helpers for provider credential UI schemas and secret extraction.

  Credential schemas describe user-facing fields. Secret values remain transient
  and are normalized here before Accounts stores them in Vault.
  """

  alias Fizz.Integrations.Catalog

  @type field :: %{
          key: String.t(),
          label: String.t(),
          input_type: String.t(),
          placeholder: String.t() | nil,
          autocomplete: String.t() | nil,
          required: boolean(),
          secret?: boolean(),
          order: integer()
        }

  @spec definition(String.t()) :: {:ok, struct()} | {:error, term()}
  def definition(provider_id) when is_binary(provider_id), do: Catalog.credential(provider_id)

  @spec ui_schema(String.t()) :: map()
  def ui_schema(provider_id) when is_binary(provider_id) do
    case definition(provider_id) do
      {:ok, %{ui_schema: schema}} when is_map(schema) -> schema
      _ -> %{"type" => "object", "properties" => %{}}
    end
  end

  @spec fields(String.t()) :: [field()]
  def fields(provider_id) when is_binary(provider_id) do
    schema = ui_schema(provider_id)
    required = schema |> Map.get("required", []) |> MapSet.new()

    schema
    |> Map.get("properties", %{})
    |> Enum.map(fn {key, property} -> field_from_schema(key, property, required) end)
    |> Enum.sort_by(&{&1.order, &1.key})
  end

  @spec defaults(String.t()) :: map()
  def defaults(provider_id) when is_binary(provider_id) do
    provider_id
    |> fields()
    |> Map.new(fn field -> {field.key, field_default(provider_id, field.key)} end)
  end

  @spec secret_value(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def secret_value(provider_id, attrs) when is_binary(provider_id) and is_map(attrs) do
    case secret_fields(provider_id) do
      [] ->
        legacy_secret_value(attrs)

      [field] ->
        attrs
        |> credential_value(field.key)
        |> normalize_secret_value()

      fields ->
        credential_values = credential_values(attrs)

        with :ok <- validate_secret_fields(fields, credential_values) do
          {:ok, Jason.encode!(Map.take(credential_values, Enum.map(fields, & &1.key)))}
        end
    end
  end

  defp secret_fields(provider_id), do: Enum.filter(fields(provider_id), & &1.secret?)

  defp field_from_schema(key, property, required) when is_map(property) do
    ui = Map.get(property, "ui", %{})

    %{
      key: key,
      label: Map.get(property, "title") || Phoenix.Naming.humanize(key),
      input_type: input_type(property, ui),
      placeholder: Map.get(ui, "placeholder"),
      autocomplete: Map.get(ui, "autocomplete"),
      required: MapSet.member?(required, key),
      secret?: secret_field?(property),
      order: Map.get(ui, "order", 100)
    }
  end

  defp input_type(_property, %{"component" => "password"}), do: "password"
  defp input_type(%{"format" => "password"}, _ui), do: "password"
  defp input_type(%{"type" => "number"}, _ui), do: "number"
  defp input_type(_property, _ui), do: "text"

  defp secret_field?(%{"writeOnly" => true}), do: true
  defp secret_field?(%{"secret" => true}), do: true
  defp secret_field?(%{"ui" => %{"component" => "password"}}), do: true
  defp secret_field?(_property), do: false

  defp field_default(provider_id, key) do
    provider_id
    |> ui_schema()
    |> get_in(["properties", key, "default"])
    |> case do
      nil -> ""
      value -> value
    end
  end

  defp credential_value(attrs, key) do
    attrs
    |> credential_values()
    |> Map.get(key)
    |> case do
      nil -> direct_credential_value(attrs, key)
      value -> value
    end
  end

  defp direct_credential_value(attrs, "secret"),
    do:
      Map.get(attrs, "secret") || Map.get(attrs, :secret) || Map.get(attrs, "value") ||
        Map.get(attrs, :value)

  defp direct_credential_value(attrs, "value"),
    do:
      Map.get(attrs, "value") || Map.get(attrs, :value) || Map.get(attrs, "secret") ||
        Map.get(attrs, :secret)

  defp direct_credential_value(attrs, key), do: Map.get(attrs, key)

  defp credential_values(attrs) do
    case Map.get(attrs, :credentials) || Map.get(attrs, "credentials") do
      values when is_map(values) -> values
      _values -> %{}
    end
  end

  defp validate_secret_fields(fields, credential_values) do
    missing? =
      Enum.any?(fields, fn field ->
        field.required and
          not match?({:ok, _value}, normalize_secret_value(Map.get(credential_values, field.key)))
      end)

    if missing?, do: {:error, :missing_secret_value}, else: :ok
  end

  defp legacy_secret_value(attrs) do
    attrs
    |> Map.get(:secret, Map.get(attrs, "secret", Map.get(attrs, :value, Map.get(attrs, "value"))))
    |> normalize_secret_value()
  end

  defp normalize_secret_value(secret) when is_binary(secret) do
    trimmed_secret = String.trim(secret)

    if byte_size(trimmed_secret) > 0 do
      {:ok, trimmed_secret}
    else
      {:error, :missing_secret_value}
    end
  end

  defp normalize_secret_value(_secret), do: {:error, :missing_secret_value}
end
