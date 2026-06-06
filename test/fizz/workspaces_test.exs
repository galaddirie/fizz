defmodule Fizz.WorkspacesTest do
  use Fizz.DataCase, async: false

  import Fizz.AccountsFixtures

  alias Fizz.Accounts.Scope
  alias Fizz.Workspaces
  alias Fizz.Workspaces.{ConsoleSession, Workspace}
  alias Fizz.WorkOSHTTPMock

  test "list_project_workspaces/2 returns unauthenticated when scope is nil" do
    assert {:error, :unauthenticated} =
             Workspaces.list_project_workspaces(nil, Ecto.UUID.generate())
  end

  test "create_workspace/3 returns unauthenticated when scope is nil" do
    assert {:error, :unauthenticated} =
             Workspaces.create_workspace(nil, Ecto.UUID.generate(), %{"name" => "demo"})
  end

  test "queue_job/4 returns unauthenticated when scope is nil" do
    assert {:error, :unauthenticated} =
             Workspaces.queue_job(nil, Ecto.UUID.generate(), Ecto.UUID.generate(), %{
               "command" => "echo hi"
             })
  end

  describe "close_console/5" do
    setup do
      previous_http_client = Application.get_env(:fizz, :workos_http_client_module)
      previous_workos_http_backoff_ms = Application.get_env(:fizz, :workos_http_backoff_ms)
      previous_workos_client = Application.get_env(:workos, WorkOS.Client)
      store_pid = start_supervised!({Agent, fn -> [] end})

      :ok = WorkOSHTTPMock.configure(self(), store_pid)
      Application.put_env(:fizz, :workos_http_client_module, WorkOSHTTPMock)
      Application.put_env(:fizz, :workos_http_backoff_ms, 0)

      Application.put_env(:workos, WorkOS.Client,
        api_key: "sk_test_123",
        client_id: "client_test_123",
        client: Fizz.Accounts.WorkOS.ReqClient
      )

      on_exit(fn ->
        restore_env(:fizz, :workos_http_client_module, previous_http_client)
        restore_env(:fizz, :workos_http_backoff_ms, previous_workos_http_backoff_ms)
        restore_env(:workos, WorkOS.Client, previous_workos_client)
        WorkOSHTTPMock.reset()
      end)

      user = user_fixture()
      org_id = "org_#{System.unique_integer([:positive])}"

      owner_scope =
        organization_scope_fixture(user: user, organization_id: org_id, organization_role: :owner)

      project = project_fixture(owner_scope, %{name: "Project #{System.unique_integer()}"})
      workspace = workspace_fixture(project.id, user.id)
      console_session = console_session_fixture(project.id, workspace.id, user.id)

      WorkOSHTTPMock.put_responses([
        membership_response(user.workos_user_id, org_id),
        membership_response(user.workos_user_id, org_id)
      ])

      %{
        scope: Scope.for_user(user),
        project: project,
        workspace: workspace,
        console_session: console_session
      }
    end

    test "closes once and preserves the first close reason on repeated calls", %{
      scope: scope,
      project: project,
      workspace: workspace,
      console_session: console_session
    } do
      topic = "workspace_console:#{console_session.id}"
      FizzWeb.Endpoint.subscribe(topic)

      assert {:ok, closed_session} =
               Workspaces.close_console(
                 scope,
                 project.id,
                 workspace.id,
                 console_session.id,
                 "runner_down"
               )

      assert closed_session.state == :closed
      assert closed_session.close_reason == "runner_down"

      assert_receive %Phoenix.Socket.Broadcast{
        topic: ^topic,
        event: "closed",
        payload: %{reason: "runner_down"}
      }

      assert {:ok, already_closed_session} =
               Workspaces.close_console(
                 scope,
                 project.id,
                 workspace.id,
                 console_session.id,
                 "disconnect"
               )

      assert already_closed_session.state == :closed
      assert already_closed_session.close_reason == "runner_down"
      refute_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "closed"}
    end
  end

  defp workspace_fixture(project_id, user_id) do
    unique = System.unique_integer([:positive])

    %Workspace{}
    |> Workspace.changeset(%{
      project_id: project_id,
      created_by_user_id: user_id,
      name: "workspace#{unique}",
      remote_name: "remote-#{unique}",
      status: :ready
    })
    |> Repo.insert!()
  end

  defp console_session_fixture(project_id, workspace_id, user_id) do
    %ConsoleSession{}
    |> ConsoleSession.changeset(%{
      project_id: project_id,
      workspace_id: workspace_id,
      opened_by_user_id: user_id,
      state: :active,
      opened_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp membership_response(workos_user_id, organization_id) do
    {:ok,
     %Req.Response{
       status: 200,
       body: %{
         "data" => [
           %{
             "id" => "om_#{organization_id}",
             "status" => "active",
             "user_id" => workos_user_id,
             "organization_id" => organization_id,
             "role" => %{"slug" => "owner"}
           }
         ]
       }
     }}
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
