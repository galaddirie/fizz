defmodule Fizz.Accounts.Integrations do
  @moduledoc """
  Integration primitives for connected apps (WorkOS Pipes) and
  BYO credential metadata (WorkOS Vault).
  """

  import Ecto.Query, warn: false

  alias Fizz.Accounts.{ByoCredential, Scope, Tenant, TenantMembership, User, WorkOS}
  alias Fizz.Repo

  @providers [
    %{
      slug: "github",
      name: "GitHub",
      category: "Development",
      description: "Repositories, pull requests, and CI metadata."
    },
    %{
      slug: "google_drive",
      name: "Google Drive",
      category: "Productivity",
      description: "Docs, spreadsheets, and shared files."
    },
    %{
      slug: "slack",
      name: "Slack",
      category: "Collaboration",
      description: "Channels, messages, and notification workflows."
    },
    %{
      slug: "microsoft_teams",
      name: "Microsoft Teams",
      category: "Collaboration",
      description: "Teams channels and conversation context."
    }
  ]

  @default_widget_scopes ["widgets:pipes:manage", "widgets:api_keys:manage"]

  @doc """
  Returns the supported provider catalog for connected apps.
  """
  def supported_providers, do: @providers

  @doc """
  Lists provider connection statuses for the current scope.
  """
  def list_connected_app_statuses(scope, opts \\ [])

  def list_connected_app_statuses(%Scope{user: %User{} = user} = scope, opts) do
    with workos_user_id when is_binary(workos_user_id) <- user.workos_user_id do
      organization_id = resolve_workos_organization_id(scope)
      statuses = build_provider_statuses(workos_user_id, organization_id, opts)

      {:ok, statuses}
    else
      _ -> {:error, :missing_workos_user_id}
    end
  end

  def list_connected_app_statuses(_scope, _opts), do: {:error, :unauthenticated}

  @doc """
  Generates a widget token for the current user/scope.
  """
  def generate_widget_token(scope, scopes \\ @default_widget_scopes)

  def generate_widget_token(
        %Scope{user: %User{workos_user_id: workos_user_id}} = scope,
        scopes
      )
      when is_list(scopes) do
    with true <- is_binary(workos_user_id),
         {:ok, token} <-
           WorkOS.generate_widget_token(%{
             user_id: workos_user_id,
             organization_id: resolve_workos_organization_id(scope),
             scopes: scopes
           }) do
      {:ok, token}
    else
      false -> {:error, :missing_workos_user_id}
      {:error, reason} -> {:error, reason}
    end
  end

  def generate_widget_token(_scope, _scopes), do: {:error, :unauthenticated}

  @doc """
  Lists BYO credential metadata records for the current user.
  """
  def list_byo_credentials(%Scope{user: %User{id: user_id}, tenant: %Tenant{id: tenant_id}}) do
    from(c in ByoCredential,
      where:
        c.user_id == ^user_id and
          (c.tenant_id == ^tenant_id or is_nil(c.tenant_id)),
      order_by: [desc: c.inserted_at]
    )
    |> Repo.all()
  end

  def list_byo_credentials(%Scope{user: %User{id: user_id}}) do
    from(c in ByoCredential, where: c.user_id == ^user_id, order_by: [desc: c.inserted_at])
    |> Repo.all()
  end

  def list_byo_credentials(_scope), do: []

  @doc """
  Returns the input changeset for the BYO credential form.
  """
  def change_byo_credential(attrs \\ %{}) do
    attrs = normalize_attrs(attrs)
    byo_credential_input_changeset(attrs)
  end

  @doc """
  Creates a BYO credential by storing the secret in WorkOS Vault and metadata locally.
  """
  def create_byo_credential(%Scope{user: %User{} = user} = scope, attrs) do
    attrs = normalize_attrs(attrs)
    changeset = byo_credential_input_changeset(attrs)

    with {:ok, input} <- Ecto.Changeset.apply_action(changeset, :insert),
         {:ok, object} <-
           WorkOS.create_vault_object(%{
             name: vault_object_name(input.provider, input.label, user.id),
             value: input.secret,
             context: vault_context(scope, input.provider)
           }),
         {:ok, vault_object_id} <- extract_object_id(object),
         {:ok, credential} <- insert_byo_credential(scope, input, vault_object_id) do
      {:ok, credential}
    else
      {:error, %Ecto.Changeset{} = error_changeset} ->
        {:error, error_changeset}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def create_byo_credential(_scope, _attrs), do: {:error, :unauthenticated}

  @doc """
  Revokes a BYO credential and best-effort deletes its vault object.
  """
  def revoke_byo_credential(%Scope{} = scope, credential_id) do
    with {:ok, credential} <- fetch_credential(scope, credential_id),
         :ok <- maybe_delete_vault_object(credential),
         {:ok, updated_credential} <-
           credential
           |> ByoCredential.revoke_changeset()
           |> Repo.update() do
      {:ok, updated_credential}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def revoke_byo_credential(_scope, _credential_id), do: {:error, :unauthenticated}

  defp build_provider_statuses(workos_user_id, organization_id, opts) do
    max_concurrency = Keyword.get(opts, :max_concurrency, System.schedulers_online())

    @providers
    |> Task.async_stream(
      fn provider ->
        provider_status(provider, workos_user_id, organization_id)
      end,
      timeout: :infinity,
      max_concurrency: max_concurrency,
      ordered: true
    )
    |> Enum.map(fn
      {:ok, status} -> status
      {:exit, reason} -> provider_error_status(reason)
    end)
  end

  defp provider_status(provider, workos_user_id, organization_id) do
    case WorkOS.get_pipes_access_token(%{
           provider: provider.slug,
           user_id: workos_user_id,
           organization_id: organization_id
         }) do
      {:ok, %{active: true, access_token: access_token}} ->
        %{
          slug: provider.slug,
          name: provider.name,
          category: provider.category,
          description: provider.description,
          connected?: true,
          status: :connected,
          message: "Connected",
          granted_scopes: access_token.scopes,
          missing_scopes: access_token.missing_scopes
        }

      {:ok, %{active: false, error: error}} ->
        disconnected_status(provider, error)

      {:error, :workos_not_configured} ->
        %{
          slug: provider.slug,
          name: provider.name,
          category: provider.category,
          description: provider.description,
          connected?: false,
          status: :unavailable,
          message: "WorkOS is not configured in this environment.",
          granted_scopes: [],
          missing_scopes: []
        }

      {:error, reason} ->
        disconnected_status(provider, reason)
    end
  end

  defp disconnected_status(provider, "needs_reauthorization") do
    %{
      slug: provider.slug,
      name: provider.name,
      category: provider.category,
      description: provider.description,
      connected?: false,
      status: :needs_reauthorization,
      message: "Reconnect required.",
      granted_scopes: [],
      missing_scopes: []
    }
  end

  defp disconnected_status(provider, "not_connected") do
    %{
      slug: provider.slug,
      name: provider.name,
      category: provider.category,
      description: provider.description,
      connected?: false,
      status: :not_connected,
      message: "Not connected yet.",
      granted_scopes: [],
      missing_scopes: []
    }
  end

  defp disconnected_status(provider, _reason) do
    %{
      slug: provider.slug,
      name: provider.name,
      category: provider.category,
      description: provider.description,
      connected?: false,
      status: :unavailable,
      message: "Connection status unavailable.",
      granted_scopes: [],
      missing_scopes: []
    }
  end

  defp provider_error_status(reason) do
    %{
      slug: "unknown",
      name: "Unknown provider",
      category: "N/A",
      description: "Provider status failed to load.",
      connected?: false,
      status: :unavailable,
      message: "Status worker failed: #{inspect(reason)}",
      granted_scopes: [],
      missing_scopes: []
    }
  end

  defp byo_credential_input_changeset(attrs) do
    types = %{provider: :string, label: :string, secret: :string}

    {%{}, types}
    |> Ecto.Changeset.cast(attrs, [:provider, :label, :secret])
    |> Ecto.Changeset.validate_required([:provider, :label, :secret])
    |> Ecto.Changeset.validate_length(:provider, min: 2, max: 80)
    |> Ecto.Changeset.validate_length(:label, min: 2, max: 120)
    |> Ecto.Changeset.validate_length(:secret, min: 8, max: 10_000)
    |> Ecto.Changeset.update_change(:provider, &String.downcase/1)
  end

  defp insert_byo_credential(
         %Scope{user: %User{id: user_id}, tenant: tenant},
         input,
         vault_object_id
       ) do
    tenant_id =
      case tenant do
        %Tenant{id: id} -> id
        _ -> nil
      end

    metadata = %{"source" => "workos_vault"}

    %ByoCredential{user_id: user_id}
    |> ByoCredential.create_changeset(%{
      provider: input.provider,
      label: input.label,
      vault_object_id: vault_object_id,
      tenant_id: tenant_id,
      metadata: metadata
    })
    |> Repo.insert()
  end

  defp fetch_credential(%Scope{user: %User{id: user_id}}, credential_id)
       when is_binary(credential_id) do
    case Integer.parse(credential_id) do
      {id, ""} -> fetch_credential(%Scope{user: %User{id: user_id}}, id)
      _ -> {:error, :not_found}
    end
  end

  defp fetch_credential(%Scope{user: %User{id: user_id}}, credential_id)
       when is_integer(credential_id) do
    case Repo.get_by(ByoCredential, id: credential_id, user_id: user_id) do
      %ByoCredential{} = credential -> {:ok, credential}
      nil -> {:error, :not_found}
    end
  end

  defp fetch_credential(_scope, _credential_id), do: {:error, :not_found}

  defp maybe_delete_vault_object(%ByoCredential{status: :revoked}), do: :ok

  defp maybe_delete_vault_object(%ByoCredential{vault_object_id: vault_object_id})
       when is_binary(vault_object_id) do
    case WorkOS.delete_vault_object(vault_object_id) do
      :ok -> :ok
      {:error, {:workos_http_error, 404, _body}} -> :ok
      {:error, {:workos_error, "not_found", _message, 404}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_delete_vault_object(_credential), do: :ok

  defp extract_object_id(%{id: id}) when is_binary(id), do: {:ok, id}
  defp extract_object_id(%{"id" => id}) when is_binary(id), do: {:ok, id}
  defp extract_object_id(_object), do: {:error, :invalid_vault_object}

  defp resolve_workos_organization_id(%Scope{tenant: %Tenant{workos_organization_id: org_id}})
       when is_binary(org_id),
       do: org_id

  defp resolve_workos_organization_id(%Scope{user: %User{id: user_id}}) do
    from(t in Tenant,
      join: tm in TenantMembership,
      on: tm.tenant_id == t.id,
      where: tm.user_id == ^user_id and not is_nil(t.workos_organization_id),
      order_by: [asc: tm.inserted_at],
      limit: 1,
      select: t.workos_organization_id
    )
    |> Repo.one()
  end

  defp resolve_workos_organization_id(_scope), do: nil

  defp vault_context(%Scope{} = scope, provider) do
    base_context = %{"provider" => provider}

    user_context =
      case scope do
        %Scope{user: %User{id: user_id}} ->
          Map.put(base_context, "user_id", Integer.to_string(user_id))

        _ ->
          base_context
      end

    case scope do
      %Scope{tenant: %Tenant{id: tenant_id}} ->
        Map.put(user_context, "tenant_id", Integer.to_string(tenant_id))

      _ ->
        user_context
    end
  end

  defp vault_object_name(provider, label, user_id) do
    "fizz-#{provider}-#{user_id}-#{slugify_label(label)}"
  end

  defp slugify_label(label) do
    label
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "credential"
      slug -> slug
    end
  end

  defp normalize_attrs(attrs) when is_map(attrs) do
    attrs
    |> Enum.into(%{}, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp normalize_attrs(_attrs), do: %{}
end
