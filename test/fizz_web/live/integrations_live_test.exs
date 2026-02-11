defmodule FizzWeb.IntegrationsLiveTest do
  use FizzWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Fizz.Accounts.ByoCredential
  alias Fizz.Repo

  defmodule ReqMock do
    def request(opts) do
      if pid = Application.get_env(:fizz, :workos_req_mock_test_pid) do
        send(pid, {:workos_http_request, opts})
      end

      agent = Application.fetch_env!(:fizz, :workos_req_mock_agent)

      Agent.get_and_update(agent, fn
        [response | rest] -> {response, rest}
        [] -> {{:error, :no_mock_response}, []}
      end)
    end
  end

  describe "unauthenticated access" do
    test "redirects to WorkOS auth", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/auth/workos"}}} =
               live(conn, ~p"/settings/integrations")
    end
  end

  describe "authenticated access" do
    setup :register_and_log_in_user

    test "renders integrations management view", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings/integrations")

      assert has_element?(view, "#integration-settings")
      assert has_element?(view, "#connections-refresh-button")
      assert has_element?(view, "#connected-apps-section")
      assert has_element?(view, "#byo-credential-form")
      assert has_element?(view, "#byo-credentials-table")
    end
  end

  describe "credential interactions" do
    setup :register_and_log_in_user

    setup do
      agent = start_supervised!({Agent, fn -> [] end})

      previous_http_client = Application.get_env(:fizz, :workos_http_client_module)
      previous_workos_client = Application.get_env(:workos, WorkOS.Client)
      previous_agent = Application.get_env(:fizz, :workos_req_mock_agent)
      previous_pid = Application.get_env(:fizz, :workos_req_mock_test_pid)

      Application.put_env(:fizz, :workos_http_client_module, ReqMock)
      Application.put_env(:fizz, :workos_req_mock_agent, agent)
      Application.put_env(:fizz, :workos_req_mock_test_pid, self())

      Application.put_env(:workos, WorkOS.Client,
        api_key: "sk_test_123",
        client_id: "client_test_123",
        client: Fizz.WorkOS.ReqClient
      )

      on_exit(fn ->
        restore_env(:fizz, :workos_http_client_module, previous_http_client)
        restore_env(:workos, WorkOS.Client, previous_workos_client)
        restore_env(:fizz, :workos_req_mock_agent, previous_agent)
        restore_env(:fizz, :workos_req_mock_test_pid, previous_pid)
      end)

      %{agent: agent}
    end

    test "creates a BYO credential", %{conn: conn, user: user, agent: agent} do
      queue_http_responses(
        agent,
        mount_responses() ++ [vault_create_response("vault_obj_live_1")]
      )

      {:ok, view, _html} = live(conn, ~p"/settings/integrations")

      view
      |> form("#byo-credential-form",
        credential: %{
          provider: "github",
          label: "Automation token",
          secret: "12345678"
        }
      )
      |> render_submit()

      assert has_element?(view, "#byo-credentials-table tr")

      credential =
        Repo.get_by!(ByoCredential,
          user_id: user.id,
          provider: "github",
          label: "Automation token",
          vault_object_id: "vault_obj_live_1"
        )

      assert credential.status == :active
    end

    test "revokes an existing BYO credential", %{conn: conn, user: user, agent: agent} do
      credential =
        Repo.insert!(%ByoCredential{
          user_id: user.id,
          provider: "slack",
          label: "Slack bot token",
          vault_object_id: "vault_obj_revoke_live",
          status: :active,
          metadata: %{}
        })

      queue_http_responses(agent, mount_responses() ++ [vault_delete_response()])

      {:ok, view, _html} = live(conn, ~p"/settings/integrations")

      view
      |> element("#revoke-credential-#{credential.id}")
      |> render_click()

      persisted_credential = Repo.get!(ByoCredential, credential.id)
      assert persisted_credential.status == :revoked
      assert persisted_credential.revoked_at
    end
  end

  defp mount_responses do
    for _ <- 1..4 do
      {:ok, %Req.Response{status: 200, body: %{"active" => false, "error" => "not_connected"}}}
    end
  end

  defp vault_create_response(id) do
    {:ok, %Req.Response{status: 201, body: %{"id" => id}}}
  end

  defp vault_delete_response do
    {:ok, %Req.Response{status: 204, body: %{}}}
  end

  defp queue_http_responses(agent, responses) when is_list(responses) do
    Agent.update(agent, fn _ -> responses end)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
