defmodule Fizz.WorkOSClientMock do
  @moduledoc false

  @behaviour Fizz.Integrations.WorkOSClient

  @owner_key {__MODULE__, :owner}
  @store_key {__MODULE__, :store}

  alias Fizz.Accounts.User

  def configure(owner, store_pid) when is_pid(owner) and is_pid(store_pid) do
    :persistent_term.put(@owner_key, owner)
    :persistent_term.put(@store_key, store_pid)
    :ok
  end

  def reset do
    :persistent_term.erase(@owner_key)
    :persistent_term.erase(@store_key)
    :ok
  end

  def put_response(method, response) when is_atom(method) do
    put_responses(method, [response])
  end

  def put_responses(method, responses) when is_atom(method) and is_list(responses) do
    Agent.update(store_pid!(), fn state ->
      Map.put(state, method, responses)
    end)
  end

  def put_responses(responses_by_method) when is_map(responses_by_method) do
    normalized =
      Enum.into(responses_by_method, %{}, fn {method, responses} ->
        {method, List.wrap(responses)}
      end)

    Agent.update(store_pid!(), fn _state -> normalized end)
  end

  @impl true
  def ensure_user(%User{} = user) do
    dispatch(:ensure_user, [user], fn ->
      {:ok, user.workos_user_id || "user_#{user.id}"}
    end)
  end

  @impl true
  def ensure_organization_membership(organization_id, %User{} = user, role) do
    dispatch(:ensure_organization_membership, [organization_id, user, role], fn ->
      {:ok,
       %{
         user_id: user.workos_user_id || "user_#{user.id}",
         membership_id: "om_#{organization_id}_#{user.id}"
       }}
    end)
  end

  @impl true
  def create_audit_event(organization_id, actor, action, targets, context) do
    dispatch(:create_audit_event, [organization_id, actor, action, targets, context], fn ->
      :ok
    end)
  end

  @impl true
  def authorization_url(params) do
    dispatch(:authorization_url, [params], fn ->
      {:ok, "https://auth.workos.test/authorize"}
    end)
  end

  @impl true
  def authenticate_with_code(params) do
    dispatch(:authenticate_with_code, [params], fn ->
      {:error, :missing_mocked_authentication}
    end)
  end

  @impl true
  def authenticate_with_refresh_token(params) do
    dispatch(:authenticate_with_refresh_token, [params], fn ->
      {:error, :missing_mocked_authentication}
    end)
  end

  @impl true
  def extract_user_profile(authentication) do
    dispatch(:extract_user_profile, [authentication], fn ->
      Fizz.Accounts.WorkOS.extract_user_profile(authentication)
    end)
  end

  @impl true
  def extract_session(authentication) do
    dispatch(:extract_session, [authentication], fn ->
      Fizz.Accounts.WorkOS.extract_session(authentication)
    end)
  end

  @impl true
  def list_user_organization_memberships(workos_user_id) do
    dispatch(:list_user_organization_memberships, [workos_user_id], fn ->
      {:ok, []}
    end)
  end

  @impl true
  def get_user_organization_membership(workos_user_id, organization_id) do
    dispatch(:get_user_organization_membership, [workos_user_id, organization_id], fn ->
      {:error, :forbidden}
    end)
  end

  @impl true
  def user_has_organization_membership?(workos_user_id, organization_id) do
    dispatch(:user_has_organization_membership?, [workos_user_id, organization_id], fn ->
      {:ok, true}
    end)
  end

  @impl true
  def generate_widget_token(params) do
    dispatch(:generate_widget_token, [params], fn ->
      {:ok, "widget_token_mock"}
    end)
  end

  @impl true
  def get_pipes_access_token(provider, user_id, organization_id) do
    dispatch(:get_pipes_access_token, [provider, user_id, organization_id], fn ->
      {:ok,
       %{
         active: true,
         access_token: "token_mock",
         expires_at: nil,
         scopes: [],
         missing_scopes: [],
         error: nil
       }}
    end)
  end

  @impl true
  def create_vault_object(params) do
    dispatch(:create_vault_object, [params], fn ->
      {:ok, %{"id" => "vault_obj_mock"}}
    end)
  end

  @impl true
  def delete_vault_object(object_id) do
    dispatch(:delete_vault_object, [object_id], fn -> :ok end)
  end

  defp dispatch(method, args, default_fun) when is_function(default_fun, 0) do
    notify(method, args)

    case pop_response(method) do
      {:ok, response} -> resolve_response(response, args)
      :empty -> default_fun.()
    end
  end

  defp resolve_response({:raise, exception}, _args), do: raise(exception)

  defp resolve_response(response, args) do
    arity = length(args)

    if is_function(response, arity) do
      apply(response, args)
    else
      response
    end
  end

  defp notify(method, args) do
    case :persistent_term.get(@owner_key, nil) do
      owner when is_pid(owner) ->
        send(owner, {:workos_client_call, method, args})
        :ok

      _ ->
        :ok
    end
  end

  defp pop_response(method) do
    Agent.get_and_update(store_pid!(), fn state ->
      case Map.get(state, method, []) do
        [response | rest] -> {{:ok, response}, Map.put(state, method, rest)}
        [] -> {:empty, state}
      end
    end)
  end

  defp store_pid! do
    case :persistent_term.get(@store_key, nil) do
      store_pid when is_pid(store_pid) -> store_pid
      _ -> raise "WorkOSClientMock is not configured"
    end
  end
end
