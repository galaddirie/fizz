defmodule Fizz.Integrations.Library.Google.Sheets.ColumnsResolverTest do
  use Fizz.DataCase, async: false

  alias Fizz.Accounts.OauthConnection
  alias Fizz.Accounts.Scope
  alias Fizz.Integrations.Library.Google.Sheets.ColumnsResolver
  alias Fizz.Repo
  alias Fizz.WorkOSHTTPMock

  import Fizz.AccountsFixtures

  setup context do
    previous_google_sheets_req_options =
      Application.get_env(:fizz, :google_sheets_req_options)

    previous_http_client = Application.get_env(:fizz, :workos_http_client_module)
    previous_workos_http_backoff_ms = Application.get_env(:fizz, :workos_http_backoff_ms)
    previous_workos_client = Application.get_env(:workos, WorkOS.Client)
    store_pid = start_supervised!({Agent, fn -> [] end})

    Req.Test.set_req_test_from_context(context)
    Req.Test.verify_on_exit!(context)

    Application.put_env(:fizz, :google_sheets_req_options, plug: {Req.Test, __MODULE__})
    :ok = WorkOSHTTPMock.configure(self(), store_pid)
    Application.put_env(:fizz, :workos_http_client_module, WorkOSHTTPMock)
    Application.put_env(:fizz, :workos_http_backoff_ms, 0)

    Application.put_env(:workos, WorkOS.Client,
      api_key: "sk_test_123",
      client_id: "client_test_123",
      client: Fizz.Accounts.WorkOS.ReqClient
    )

    on_exit(fn ->
      restore_env(:fizz, :google_sheets_req_options, previous_google_sheets_req_options)
      restore_env(:fizz, :workos_http_client_module, previous_http_client)
      restore_env(:fizz, :workos_http_backoff_ms, previous_workos_http_backoff_ms)
      restore_env(:workos, WorkOS.Client, previous_workos_client)
      WorkOSHTTPMock.reset()
    end)

    :ok
  end

  describe "resolve/1" do
    test "returns empty options when spreadsheet_id is missing" do
      user = user_fixture()
      scope = Scope.for_user(user) |> Scope.with_organization_id("org_columns_no_sheet")

      assert {:ok, []} =
               ColumnsResolver.resolve(%{
                 q: "",
                 params: %{"sheet_name" => "Sheet1"},
                 context: %{current_scope: scope, project_id: "proj_1"}
               })
    end

    test "returns empty options when sheet_name is missing" do
      user = user_fixture()
      scope = Scope.for_user(user) |> Scope.with_organization_id("org_columns_no_sheet_name")

      assert {:ok, []} =
               ColumnsResolver.resolve(%{
                 q: "",
                 params: %{"spreadsheet_id" => "sheet_123"},
                 context: %{current_scope: scope, project_id: "proj_1"}
               })
    end

    test "returns empty table options when spreadsheet_id is missing in tables mode" do
      user = user_fixture()
      scope = Scope.for_user(user) |> Scope.with_organization_id("org_tables_no_sheet")

      assert {:ok, []} =
               ColumnsResolver.resolve(%{
                 q: "",
                 params: %{"mode" => "tables"},
                 context: %{current_scope: scope, project_id: "proj_1"}
               })
    end

    test "returns empty options when current_scope is missing" do
      assert {:ok, []} =
               ColumnsResolver.resolve(%{
                 q: "",
                 params: %{"spreadsheet_id" => "sheet_123", "sheet_name" => "Sheet1"},
                 context: %{project_id: "proj_1"}
               })
    end

    test "returns empty options when project_id is missing" do
      user = user_fixture()
      scope = Scope.for_user(user) |> Scope.with_organization_id("org_columns_no_project")

      assert {:ok, []} =
               ColumnsResolver.resolve(%{
                 q: "",
                 params: %{"spreadsheet_id" => "sheet_123", "sheet_name" => "Sheet1"},
                 context: %{current_scope: scope}
               })
    end

    test "surfaces :no_google_credential when none is connected for the scope" do
      user = user_fixture()

      scope =
        Scope.for_user(user)
        |> Scope.with_organization_id("org_columns_no_credential")

      assert {:error, :no_google_credential} =
               ColumnsResolver.resolve(%{
                 q: "",
                 params: %{
                   "spreadsheet_id" => "sheet_123",
                   "sheet_name" => "Sheet1"
                 },
                 context: %{current_scope: scope, project_id: "proj_no_creds"}
               })
    end

    test "surfaces :no_google_credential for table lookup when none is connected for the scope" do
      user = user_fixture()

      scope =
        Scope.for_user(user)
        |> Scope.with_organization_id("org_tables_no_credential")

      assert {:error, :no_google_credential} =
               ColumnsResolver.resolve(%{
                 q: "",
                 params: %{
                   "mode" => "tables",
                   "spreadsheet_id" => "sheet_123"
                 },
                 context: %{current_scope: scope, project_id: "proj_no_creds"}
               })
    end

    test "returns table options with generic parent and schema aliases" do
      scope = Fizz.WorkflowsFixtures.project_scope_fixture()
      connection = insert_oauth_connection!(scope.user.id, scope.organization_id, "google_oauth")

      put_workos_responses([
        membership_response(scope.user.workos_user_id, scope.organization_id),
        membership_response(scope.user.workos_user_id, scope.organization_id),
        pipes_token_response("sheet-token")
      ])

      Req.Test.expect(__MODULE__, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        assert conn.method == "GET"
        assert conn.request_path == "/v4/spreadsheets/sheet_123"
        assert conn.query_params["fields"] =~ "sheets.tables"

        Req.Test.json(conn, %{
          "sheets" => [
            %{
              "properties" => %{"sheetId" => 0, "title" => "Orders"},
              "tables" => [
                %{
                  "tableId" => "tbl_orders",
                  "name" => "Orders Table",
                  "range" => %{
                    "sheetId" => 0,
                    "startRowIndex" => 0,
                    "endRowIndex" => 3,
                    "startColumnIndex" => 0,
                    "endColumnIndex" => 2
                  },
                  "columnProperties" => [
                    %{"columnIndex" => 0, "columnName" => "Order ID"},
                    %{"columnIndex" => 1, "columnName" => "Amount"}
                  ]
                }
              ]
            }
          ]
        })
      end)

      credential_ref = %{
        "id" => connection.id,
        "provider" => "google_oauth",
        "auth_type" => "oauth",
        "owner_user_id" => scope.user.id
      }

      assert {:ok, [table]} =
               ColumnsResolver.resolve(%{
                 q: "",
                 params: %{
                   "mode" => "tables",
                   "spreadsheet_id" => "sheet_123",
                   "credential_ref" => credential_ref
                 },
                 context: %{current_scope: scope, project_id: scope.project.id}
               })

      assert table["id"] == "tbl_orders"
      assert table["label"] == "Orders Table"
      assert table["parent_id"] == "Orders"
      assert table["parent_label"] == "Orders"

      assert Enum.map(table["schema"]["columns"], &Map.take(&1, ["id", "label"])) == [
               %{"id" => "Order ID", "label" => "Order ID"},
               %{"id" => "Amount", "label" => "Amount"}
             ]
    end

    test "does not use another user's Google credential for preview fallback" do
      scope = Fizz.WorkflowsFixtures.project_scope_fixture()
      other_user = user_fixture()

      insert_oauth_connection!(other_user.id, scope.organization_id, "google_oauth")

      put_workos_responses([
        membership_response(scope.user.workos_user_id, scope.organization_id),
        membership_response(scope.user.workos_user_id, scope.organization_id)
      ])

      assert {:error, :no_google_credential} =
               ColumnsResolver.resolve(%{
                 q: "",
                 params: %{
                   "spreadsheet_id" => "sheet_123",
                   "sheet_name" => "Sheet1"
                 },
                 context: %{current_scope: scope, project_id: scope.project.id}
               })
    end

    test "treats blank string inputs as missing" do
      user = user_fixture()

      scope =
        Scope.for_user(user) |> Scope.with_organization_id("org_columns_blank")

      assert {:ok, []} =
               ColumnsResolver.resolve(%{
                 q: "",
                 params: %{"spreadsheet_id" => "   ", "sheet_name" => "Sheet1"},
                 context: %{current_scope: scope, project_id: "proj_blank"}
               })
    end
  end

  defp insert_oauth_connection!(user_id, organization_id, provider) do
    %OauthConnection{}
    |> OauthConnection.changeset(%{
      user_id: user_id,
      workos_organization_id: organization_id,
      provider: provider,
      status: :active
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

  defp put_workos_responses(responses), do: WorkOSHTTPMock.put_responses(responses)

  defp pipes_token_response(token) do
    {:ok,
     %Req.Response{
       status: 200,
       body: %{
         "active" => true,
         "access_token" => %{"access_token" => token}
       }
     }}
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
