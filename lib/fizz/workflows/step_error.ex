defmodule Fizz.Workflows.StepError do
  @moduledoc """
  Normalized runtime error returned by step executors.

  Workflow retry decisions are made from `category`, `code`, `retryable?`, and
  `retry_after_ms`. Step implementations may keep provider-specific details in
  `body` or `details`, but the runner does not inspect those fields.
  """

  @derive {Jason.Encoder,
           only: [
             :code,
             :category,
             :message,
             :status,
             :source,
             :retry_after_ms,
             :retryable?,
             :details
           ]}
  defstruct [
    :code,
    :category,
    :message,
    :status,
    :body,
    :source,
    :retry_after_ms,
    retryable?: false,
    details: %{}
  ]

  @type category ::
          :auth
          | :credential
          | :network
          | :not_found
          | :permission
          | :provider
          | :rate_limit
          | :transient
          | :validation
          | :unknown

  @type source :: %{
          optional(:kind) => :step | atom() | String.t(),
          optional(:id) => String.t(),
          optional(:version) => pos_integer() | nil
        }

  @type t :: %__MODULE__{
          code: atom(),
          category: category(),
          message: String.t(),
          status: pos_integer() | nil,
          body: term(),
          source: source() | atom() | String.t() | nil,
          retry_after_ms: non_neg_integer() | nil,
          retryable?: boolean(),
          details: map()
        }

  @spec new(keyword() | map()) :: t()
  def new(attrs \\ []) do
    attrs = attrs_map(attrs)
    status = Map.get(attrs, :status)
    category = Map.get(attrs, :category) || category_for_status(status) || :unknown
    code = Map.get(attrs, :code) || code_for_category(category)

    %__MODULE__{
      code: code,
      category: category,
      message: message(attrs, code, category),
      status: status,
      body: Map.get(attrs, :body),
      source: Map.get(attrs, :source),
      retry_after_ms: Map.get(attrs, :retry_after_ms),
      retryable?: Map.get(attrs, :retryable?, retryable_category?(category)),
      details: Map.get(attrs, :details, %{})
    }
  end

  @spec http(map(), keyword() | map()) :: t()
  def http(response, opts \\ []) when is_map(response) do
    opts = attrs_map(opts)
    status = Map.get(response, :status) || Map.get(response, "status")
    body = Map.get(response, :body) || Map.get(response, "body")
    headers = Map.get(response, :headers) || Map.get(response, "headers") || []

    new(%{
      code: http_code(status),
      category: category_for_status(status),
      message: response_message(body, status),
      status: status,
      body: body,
      source: Map.get(opts, :source),
      retry_after_ms: retry_after_ms(headers),
      retryable?: retryable_status?(status),
      details: Map.get(opts, :details, %{})
    })
  end

  @spec network(term(), keyword() | map()) :: t()
  def network(reason, opts \\ []) do
    opts = attrs_map(opts)

    new(%{
      code: :network_error,
      category: :network,
      message: "Network request failed",
      source: Map.get(opts, :source),
      retryable?: true,
      details: %{reason: reason}
    })
  end

  @spec normalize(term(), keyword() | map()) :: t()
  def normalize(reason, opts \\ [])

  def normalize(%__MODULE__{} = error, _opts), do: error

  def normalize({:missing_param, param}, opts) do
    opts
    |> base_attrs(:missing_param, :validation, "Missing required parameter #{inspect(param)}")
    |> Map.put(:details, %{param: param})
    |> new()
  end

  def normalize({:missing_context, key}, opts) do
    opts
    |> base_attrs(:missing_context, :validation, "Missing execution context #{inspect(key)}")
    |> Map.put(:details, %{context_key: key})
    |> new()
  end

  def normalize(:credential_ref_required, opts) do
    opts
    |> base_attrs(
      :credential_ref_required,
      :credential,
      "A credential must be selected before this step can run"
    )
    |> new()
  end

  def normalize(:invalid_row_values, opts) do
    opts
    |> base_attrs(:invalid_row_values, :validation, "Row values must be a map or list")
    |> new()
  end

  def normalize(:no_header_row, opts) do
    opts
    |> base_attrs(:no_header_row, :validation, "The selected sheet does not have a header row")
    |> new()
  end

  def normalize(:table_not_found, opts) do
    opts
    |> base_attrs(:table_not_found, :not_found, "The selected table was not found")
    |> new()
  end

  def normalize(%{status: status} = response, opts) when is_integer(status),
    do: http(response, opts)

  def normalize(reason, opts) when is_atom(reason) do
    opts
    |> base_attrs(reason, :unknown, Atom.to_string(reason))
    |> new()
  end

  def normalize(reason, opts) do
    opts
    |> base_attrs(:step_failed, :unknown, inspect(reason))
    |> Map.put(:details, %{reason: reason})
    |> new()
  end

  @spec retryable?(t()) :: boolean()
  def retryable?(%__MODULE__{retryable?: retryable?}), do: retryable?

  defp attrs_map(attrs) when is_list(attrs), do: Map.new(attrs)
  defp attrs_map(attrs) when is_map(attrs), do: attrs

  defp base_attrs(opts, code, category, message) do
    opts = attrs_map(opts)

    %{
      code: code,
      category: category,
      message: message,
      source: Map.get(opts, :source),
      retryable?: Map.get(opts, :retryable?, retryable_category?(category))
    }
  end

  defp message(attrs, _code, _category) do
    case Map.get(attrs, :message) do
      value when is_binary(value) and value != "" -> value
      _ -> "Step failed"
    end
  end

  defp category_for_status(status) when status in [401], do: :auth
  defp category_for_status(status) when status in [403], do: :permission
  defp category_for_status(status) when status in [404], do: :not_found
  defp category_for_status(status) when status in [408, 425, 429], do: :rate_limit
  defp category_for_status(status) when status in 500..599, do: :transient
  defp category_for_status(status) when status in 400..499, do: :validation
  defp category_for_status(_status), do: nil

  defp code_for_category(:rate_limit), do: :rate_limited
  defp code_for_category(:transient), do: :provider_unavailable
  defp code_for_category(:network), do: :network_error
  defp code_for_category(:auth), do: :unauthorized
  defp code_for_category(:permission), do: :forbidden
  defp code_for_category(:not_found), do: :not_found
  defp code_for_category(:validation), do: :validation_failed
  defp code_for_category(:credential), do: :credential_error
  defp code_for_category(_category), do: :step_failed

  defp http_code(status) when status in [401], do: :unauthorized
  defp http_code(status) when status in [403], do: :forbidden
  defp http_code(status) when status in [404], do: :not_found
  defp http_code(status) when status in [408, 425, 429], do: :rate_limited
  defp http_code(status) when status in 500..599, do: :provider_unavailable
  defp http_code(status) when status in 400..499, do: :bad_request
  defp http_code(_status), do: :http_error

  defp retryable_status?(status) when status in [408, 425, 429], do: true
  defp retryable_status?(status) when status in 500..599, do: true
  defp retryable_status?(_status), do: false

  defp retryable_category?(category) when category in [:network, :rate_limit, :transient],
    do: true

  defp retryable_category?(_category), do: false

  defp response_message(%{"error" => %{"message" => message}}, _status)
       when is_binary(message) and message != "",
       do: message

  defp response_message(%{error: %{message: message}}, _status)
       when is_binary(message) and message != "",
       do: message

  defp response_message(body, _status) when is_binary(body) and body != "", do: body
  defp response_message(_body, status), do: "HTTP #{status}"

  defp retry_after_ms(headers) when is_list(headers) do
    Enum.find_value(headers, fn
      {"retry-after", value} -> parse_retry_after(value)
      {"Retry-After", value} -> parse_retry_after(value)
      _header -> nil
    end)
  end

  defp retry_after_ms(headers) when is_map(headers) do
    headers
    |> Map.get("retry-after")
    |> parse_retry_after_values()
  end

  defp retry_after_ms(_headers), do: nil

  defp parse_retry_after_values([value | _]), do: parse_retry_after(value)
  defp parse_retry_after_values(value), do: parse_retry_after(value)

  defp parse_retry_after(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> :timer.seconds(seconds)
      _ -> nil
    end
  end

  defp parse_retry_after(_value), do: nil
end
