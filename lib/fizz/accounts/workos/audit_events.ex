defmodule Fizz.Accounts.WorkOS.AuditEvents do
  @moduledoc """
  WorkOS audit event operations.
  """

  require Logger

  import Fizz.Accounts.WorkOS.Http

  alias Fizz.Accounts.User

  @doc """
  Emits an audit event to WorkOS for a WorkOS organization.
  """
  @spec create_audit_event(String.t(), %User{}, String.t(), [map()], map()) ::
          :ok | {:error, term()}
  def create_audit_event(
        workos_organization_id,
        %User{} = actor,
        action,
        targets,
        context
      )
      when is_binary(workos_organization_id) and is_binary(action) do
    if Fizz.Accounts.WorkOS.Memberships.enabled?() do
      event = %{
        action: action,
        actor: %{
          type: "user",
          id: actor.workos_user_id || to_string(actor.id)
        },
        occurred_at: DateTime.utc_now(:second) |> DateTime.to_iso8601(),
        targets: normalize_targets(targets),
        context: Map.new(context)
      }

      case audit_logs_module().create_event(%{
             organization_id: workos_organization_id,
             event: event
           }) do
        {:ok, _response} ->
          :ok

        {:error, error} ->
          log_error("create audit event", error)
          {:error, normalize_error(error)}
      end
    else
      :ok
    end
  rescue
    error in RuntimeError ->
      Logger.error(
        "WorkOS configuration error when creating audit event: #{Exception.message(error)}"
      )

      {:error, :workos_not_configured}
  end

  def create_audit_event(_organization, _actor, _action, _targets, _context), do: :ok

  defp normalize_targets(targets) when is_list(targets) do
    Enum.map(targets, fn target ->
      %{
        type: to_string(Map.get(target, :type) || Map.get(target, "type")),
        id: to_string(Map.get(target, :id) || Map.get(target, "id"))
      }
    end)
  end

  defp normalize_targets(_targets), do: []

  defp audit_logs_module do
    Application.get_env(:fizz, :workos_audit_logs_module, WorkOS.AuditLogs)
  end
end
