defmodule Fizz.Integrations.CredentialsResolver do
  @moduledoc """
  Resolves credential options for workflow steps via the FieldResolver pattern.
  """
  import Ecto.Query

  alias Fizz.Repo
  alias Fizz.Integrations.Credential

  def search(query \\ "", params \\ %{}, _context \\ %{}) do
    provider = Map.get(params, "provider") || Map.get(params, :provider)
    auth_type = Map.get(params, "auth_type") || Map.get(params, :auth_type)

    base_query = Credential

    # Apply filters
    filtered_query =
      base_query
      |> apply_filter(:provider, provider)
      |> apply_filter(:auth_type, auth_type)
      |> apply_search(query)
      |> limit(50)

    results = Repo.all(filtered_query)

    # Format for generic frontend consumption
    options =
      Enum.map(results, fn cred ->
        %{
          "id" => cred.id,
          "provider" => cred.provider,
          "auth_type" => cred.auth_type,
          "owner_user_id" => cred.owner_user_id,
          "display_name" => display_name(cred),
          "provider_label" => provider_label(cred),
          "status" => cred.status || "active"
        }
      end)

    {:ok, options}
  end

  defp apply_filter(query, _field, nil), do: query

  defp apply_filter(query, field, value) do
    where(query, [c], field(c, ^field) == ^value)
  end

  defp apply_search(query, nil), do: query
  defp apply_search(query, ""), do: query

  defp apply_search(query, search_term) do
    search_term = "%#{search_term}%"
    where(query, [c], ilike(c.display_name, ^search_term))
  end

  defp display_name(cred) do
    if cred.owner_display_name do
      "#{cred.display_name} (#{cred.owner_display_name})"
    else
      cred.display_name || cred.id
    end
  end

  defp provider_label(cred) do
    # Ideally fetch from provider module, but as fallback:
    cred.provider |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end
end
