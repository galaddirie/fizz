defmodule Fizz.Integrations.Google.Sheets.ClientTest do
  use Fizz.DataCase, async: false

  alias Fizz.Accounts.OauthConnection
  alias Fizz.Integrations.OperationError
  alias Fizz.Integrations.Google.Sheets.Client
  alias Fizz.Repo
  alias Fizz.Workflows.ExecutionContext
  alias Fizz.WorkOSHTTPMock

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

  describe "get_tables/3" do
    test "fills omitted native table column names from the visible header row" do
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
              "properties" => %{"sheetId" => 0, "title" => "Sheet1"},
              "tables" => [
                %{
                  "tableId" => "tbl_1",
                  "name" => "Table1",
                  "range" => %{
                    "sheetId" => 0,
                    "startRowIndex" => 0,
                    "endRowIndex" => 3,
                    "startColumnIndex" => 0,
                    "endColumnIndex" => 3
                  },
                  "columnProperties" => [
                    %{"columnIndex" => 1, "columnName" => "res"},
                    %{"columnIndex" => 2, "columnName" => "test"}
                  ]
                }
              ]
            }
          ]
        })
      end)

      Req.Test.expect(__MODULE__, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        ["/v4/spreadsheets/sheet_123", encoded_range] =
          String.split(conn.request_path, "/values/", parts: 2)

        assert conn.method == "GET"
        assert URI.decode(encoded_range) == "Sheet1!A1:C1"
        assert conn.query_params["valueRenderOption"] == "FORMATTED_VALUE"

        Req.Test.json(conn, %{"values" => [["num1", "res", "test"]]})
      end)

      params = %{
        "spreadsheet_id" => "sheet_123",
        "credential_ref" => %{
          "id" => connection.id,
          "provider" => "google_oauth",
          "auth_type" => "oauth",
          "owner_user_id" => scope.user.id
        }
      }

      context = %ExecutionContext{scope: scope, project_id: scope.project.id}

      assert {:ok, [%{"columns" => columns}]} = Client.get_tables(params, context)

      assert Enum.map(columns, &Map.get(&1, "label")) == ["num1", "res", "test"]
    end
  end

  describe "error normalization" do
    test "returns operation errors for missing required params" do
      assert {:error, %OperationError{} = error} = Client.get_sheet_names(%{}, %{})

      assert error.code == :missing_param
      assert error.category == :validation
      assert error.details == %{param: "spreadsheet_id"}
    end

    test "returns operation errors for missing credential refs" do
      assert {:error, %OperationError{} = error} =
               Client.get_sheet_names(%{"spreadsheet_id" => "sheet_123"}, %{})

      assert error.code == :credential_ref_required
      assert error.category == :credential
    end

    test "returns retryable operation errors for rate-limit responses" do
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

        conn
        |> Plug.Conn.put_status(429)
        |> Plug.Conn.put_resp_header("retry-after", "2")
        |> Req.Test.json(%{"error" => %{"message" => "quota exceeded"}})
      end)

      assert {:error, %OperationError{} = error} =
               Client.get_sheet_names(
                 client_params(scope, connection),
                 execution_context(scope)
               )

      assert error.code == :rate_limited
      assert error.category == :rate_limit
      assert error.status == 429
      assert error.retry_after_ms == 2_000
      assert error.retryable?
      assert error.message == "quota exceeded"
    end

    test "returns retryable operation errors for transient provider responses" do
      scope = Fizz.WorkflowsFixtures.project_scope_fixture()
      connection = insert_oauth_connection!(scope.user.id, scope.organization_id, "google_oauth")

      put_workos_responses([
        membership_response(scope.user.workos_user_id, scope.organization_id),
        membership_response(scope.user.workos_user_id, scope.organization_id),
        pipes_token_response("sheet-token")
      ])

      Req.Test.expect(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_status(503)
        |> Req.Test.json(%{"error" => %{"message" => "temporarily unavailable"}})
      end)

      assert {:error, %OperationError{} = error} =
               Client.get_sheet_names(
                 client_params(scope, connection),
                 execution_context(scope)
               )

      assert error.code == :provider_unavailable
      assert error.category == :transient
      assert error.status == 503
      assert error.retryable?
    end

    test "returns retryable operation errors for transport failures" do
      scope = Fizz.WorkflowsFixtures.project_scope_fixture()
      connection = insert_oauth_connection!(scope.user.id, scope.organization_id, "google_oauth")

      put_workos_responses([
        membership_response(scope.user.workos_user_id, scope.organization_id),
        membership_response(scope.user.workos_user_id, scope.organization_id),
        pipes_token_response("sheet-token")
      ])

      Req.Test.expect(__MODULE__, fn conn ->
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, %OperationError{} = error} =
               Client.get_sheet_names(
                 client_params(scope, connection),
                 execution_context(scope)
               )

      assert error.code == :network_error
      assert error.category == :network
      assert error.retryable?
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

  defp client_params(scope, connection) do
    %{
      "spreadsheet_id" => "sheet_123",
      "credential_ref" => %{
        "id" => connection.id,
        "provider" => "google_oauth",
        "auth_type" => "oauth",
        "owner_user_id" => scope.user.id
      }
    }
  end

  defp execution_context(scope), do: %ExecutionContext{scope: scope, project_id: scope.project.id}

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

  defp put_workos_responses(responses), do: WorkOSHTTPMock.put_responses(responses)

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
