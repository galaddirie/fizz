defmodule Fizz.Integrations.Providers.OpenAIApiKey do
  @moduledoc """
  OpenAI integration provider backed by user-owned Vault API credentials.

  Includes helper functions that call ReqLLM with the current user's Vault key.
  """

  @behaviour Fizz.Integrations.Provider

  alias Fizz.Accounts.{ExternalAuth, Scope}
  alias Fizz.Integrations.CredentialRef

  @type model_spec ::
          String.t()
          | {atom(), keyword()}
          | {atom(), String.t(), keyword()}
          | struct()
  @type messages :: String.t() | list() | ReqLLM.Context.t()
  @type response :: ReqLLM.Response.t()
  @type stream_response :: ReqLLM.StreamResponse.t()

  @impl true
  def provider_id, do: "openai_api_key"

  @impl true
  def display_name, do: "OpenAI"

  @impl true
  def check_connection(_scope, nil), do: {:error, :organization_scope_required}

  def check_connection(scope, organization_id) when is_binary(organization_id) do
    case ExternalAuth.resolve_credential_for_use(scope, organization_id, provider_id()) do
      {:ok, credential_result} ->
        {:ok,
         %{
           active: true,
           scopes: [],
           missing_scopes: [],
           provider_metadata: credential_metadata(credential_result),
           error: nil
         }}

      {:error, :credential_not_found} ->
        {:ok,
         %{
           active: false,
           scopes: [],
           missing_scopes: [],
           provider_metadata: %{},
           error: :credential_not_found
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def fetch_token(_scope, nil), do: {:error, :organization_scope_required}

  def fetch_token(scope, organization_id) when is_binary(organization_id) do
    with {:ok, credential_result} <-
           ExternalAuth.resolve_credential_for_use(scope, organization_id, provider_id()) do
      {:ok,
       %{
         access_token: credential_result.api_key,
         expires_at: nil,
         scopes: [],
         missing_scopes: [],
         api_credential_id: credential_result.api_credential_id,
         credential_id: credential_result.credential_id
       }}
    end
  end

  @impl true
  def network_domains do
    ["api.openai.com"]
  end

  @doc """
  Generates text through ReqLLM using the user's Vault-managed OpenAI API key.
  """
  @spec generate_text(Scope.t(), String.t(), model_spec(), messages(), keyword()) ::
          {:ok, response()} | {:error, term()}
  def generate_text(%Scope{} = scope, organization_id, model, messages, opts \\ [])
      when is_binary(organization_id) and is_list(opts) do
    with {:ok, req_llm_opts} <- req_llm_opts(scope, organization_id, opts) do
      req_llm_client().generate_text(model, messages, req_llm_opts)
    end
  end

  @doc """
  Streams text through ReqLLM using the user's Vault-managed OpenAI API key.
  """
  @spec stream_text(Scope.t(), String.t(), model_spec(), messages(), keyword()) ::
          {:ok, stream_response()} | {:error, term()}
  def stream_text(%Scope{} = scope, organization_id, model, messages, opts \\ [])
      when is_binary(organization_id) and is_list(opts) do
    with {:ok, req_llm_opts} <- req_llm_opts(scope, organization_id, opts) do
      req_llm_client().stream_text(model, messages, req_llm_opts)
    end
  end

  @doc """
  Generates a structured object through ReqLLM using the user's Vault-managed key.
  """
  @spec generate_object(
          Scope.t(),
          String.t(),
          model_spec(),
          messages(),
          keyword() | map() | term(),
          keyword()
        ) ::
          {:ok, response()} | {:error, term()}
  def generate_object(
        %Scope{} = scope,
        organization_id,
        model,
        messages,
        object_schema,
        opts \\ []
      )
      when is_binary(organization_id) and is_list(opts) do
    with {:ok, req_llm_opts} <- req_llm_opts(scope, organization_id, opts) do
      req_llm_client().generate_object(model, messages, object_schema, req_llm_opts)
    end
  end

  @doc """
  Generates images through ReqLLM using the user's Vault-managed OpenAI API key.
  """
  @spec generate_image(Scope.t(), String.t(), model_spec(), messages(), keyword()) ::
          {:ok, response()} | {:error, term()}
  def generate_image(%Scope{} = scope, organization_id, model, prompt_or_messages, opts \\ [])
      when is_binary(organization_id) and is_list(opts) do
    with {:ok, req_llm_opts} <- req_llm_opts(scope, organization_id, opts) do
      req_llm_client().generate_image(model, prompt_or_messages, req_llm_opts)
    end
  end

  defp req_llm_opts(%Scope{} = scope, organization_id, opts) when is_list(opts) do
    credential_ref = Keyword.get(opts, :credential_ref)

    with {:ok, normalized_ref} <-
           CredentialRef.normalize_for_provider(credential_ref, provider_id(), :api_key),
         :ok <- ensure_scope_owner_matches_ref(scope, normalized_ref),
         {:ok, %{access_token: api_key}} <-
           fetch_token_for_credential_ref(scope, organization_id, normalized_ref) do
      filtered_opts = Keyword.delete(opts, :credential_ref)
      {:ok, Keyword.put(filtered_opts, :api_key, api_key)}
    end
  end

  defp fetch_token_for_credential_ref(scope, organization_id, credential_ref) do
    with {:ok, credential_id} <- CredentialRef.id(credential_ref),
         {:ok, credential_result} <-
           ExternalAuth.resolve_credential_for_use(scope, organization_id, provider_id(),
             api_credential_id: credential_id
           ) do
      {:ok,
       %{
         access_token: credential_result.api_key,
         expires_at: nil,
         scopes: [],
         missing_scopes: [],
         api_credential_id: credential_result.api_credential_id,
         credential_id: credential_result.credential_id
       }}
    end
  end

  defp ensure_scope_owner_matches_ref(%Scope{user: %{id: user_id}}, credential_ref)
       when is_binary(user_id) do
    CredentialRef.ensure_owner(credential_ref, user_id)
  end

  defp ensure_scope_owner_matches_ref(_scope, _credential_ref), do: {:error, :scope_not_available}

  defp req_llm_client do
    Application.get_env(:fizz, :req_llm_client_module, ReqLLM)
  end

  defp credential_metadata(credential_result) do
    %{
      "api_credential_id" => credential_result.api_credential_id,
      "provider_label" => credential_result.provider_label,
      "provider_custom_name" => credential_result.provider_custom_name
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
