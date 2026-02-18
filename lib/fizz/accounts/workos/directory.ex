defmodule Fizz.Accounts.WorkOS.Directory do
  @moduledoc """
  WorkOS organization directory helpers scoped to the current user.
  """

  import Fizz.Accounts.WorkOS.Helpers, only: [read_value: 2, membership_role_slugs: 1]

  alias Fizz.Accounts.{Scope, User, WorkOS}

  @doc """
  Lists WorkOS organizations the current scope user belongs to.
  """
  @spec list_user_organizations(Scope.t() | nil) :: [map()]
  def list_user_organizations(%Scope{user: %User{workos_user_id: workos_user_id}})
      when is_binary(workos_user_id) do
    case WorkOS.list_user_organization_memberships(workos_user_id) do
      {:ok, memberships} ->
        memberships
        |> Enum.map(&remote_organization_entry/1)
        |> Enum.filter(& &1)
        |> Enum.uniq_by(& &1.organization_id)
        |> Enum.sort_by(& &1.organization_name)

      {:error, _reason} ->
        []
    end
  end

  def list_user_organizations(_scope), do: []

  @doc """
  Returns true when the given user has an active WorkOS membership in the org.
  """
  @spec user_has_organization?(User.t(), String.t()) :: boolean()
  def user_has_organization?(%User{workos_user_id: workos_user_id}, organization_id)
      when is_binary(workos_user_id) and is_binary(organization_id) do
    case WorkOS.user_has_organization_membership?(workos_user_id, organization_id) do
      {:ok, has_membership?} -> has_membership?
      {:error, _reason} -> false
    end
  end

  def user_has_organization?(_user, _organization_id), do: false

  defp remote_organization_entry(membership) do
    case membership_organization_id(membership) do
      organization_id when is_binary(organization_id) ->
        %{
          organization_id: organization_id,
          local_organization_id: nil,
          organization_name: membership_organization_name(membership, organization_id),
          role: organization_role_from_membership(membership)
        }

      _ ->
        nil
    end
  end

  defp membership_organization_id(%{organization_id: organization_id})
       when is_binary(organization_id),
       do: organization_id

  defp membership_organization_id(%{"organization_id" => organization_id})
       when is_binary(organization_id),
       do: organization_id

  defp membership_organization_id(_membership), do: nil

  defp membership_organization_name(membership, fallback_id) do
    case read_value(membership, [:organization, "organization"]) do
      %{} = organization ->
        read_value(organization, [:name, "name"]) || fallback_id

      _ ->
        fallback_id
    end
  end

  defp organization_role_from_membership(membership) do
    membership
    |> membership_role_slugs()
    |> Enum.find_value(:member, &normalize_role_slug/1)
  end

  defp normalize_role_slug(role_slug) when is_binary(role_slug) do
    case String.downcase(role_slug) do
      "owner" -> :owner
      "admin" -> :admin
      "member" -> :member
      _ -> nil
    end
  end

  defp normalize_role_slug(_role_slug), do: nil
end
