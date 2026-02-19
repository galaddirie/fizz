defmodule FizzWeb.Plugs.WebhookHandler do
  @moduledoc """
  Plug to handle incoming webhook triggers.

  Routes requests to `/api/hooks/:workflow_id`.
  """
  import Plug.Conn
  require Logger

  alias Fizz.Repo
  alias Fizz.Workflows.Workflow
  alias Fizz.Executions
  alias Fizz.Workers.ExecutionWorker
  alias Fizz.Accounts.Scope
  alias Fizz.Collaboration.EditSession.Server, as: EditSessionServer

  def init(opts), do: opts

  def call(conn, _opts) do
    path_segments = conn.params["path"] || []
    is_test = conn.request_path =~ ~r{/hook-test/}
    path = Enum.join(path_segments, "/")
    scope = conn.assigns[:current_scope]

    if is_test and not Scope.authenticated?(scope) do
      send_error(conn, 401, "API key required")
    else
      alias Fizz.Runtime.Triggers.Registry

      # 1. Try lookup by path first (new way)
      # Registry lookup is much faster as it bypasses DB search
      {workflow, config} =
        case Registry.lookup_webhook(path, conn.method) do
          {:ok, %{workflow_id: id, config: config}} ->
            {Repo.get(Workflow, id), config}

          :error ->
            # 2. Try lookup by ID if first segment is a UUID (legacy way)
            workflow =
              case List.first(path_segments) do
                nil ->
                  nil

                id ->
                  case Ecto.UUID.cast(id) do
                    {:ok, uuid} -> Repo.get(Workflow, uuid)
                    _ -> nil
                  end
              end

            # If it's a test route, we might need a DB lookup if registry doesn't have it
            workflow =
              if is_nil(workflow) and is_test do
                Fizz.Workflows.get_workflow_by_webhook_draft_path(path, conn.method)
              else
                workflow
              end

            {workflow, nil}
        end

      case workflow do
        nil ->
          send_error(conn, 404, "Workflow not found")

        workflow ->
          cond do
            # Test mode: triggered from /hook-test/
            # We implicitly trust the token/path for test webhooks since it comes from the draft config
            is_test ->
              workflow = Repo.preload(workflow, :draft)

              if Scope.can_edit_workflow?(scope, workflow) do
                case EditSessionServer.test_webhook_enabled?(workflow.id, path, conn.method) do
                  {:ok, _webhook_test} ->
                    config =
                      config ||
                        webhook_config_for(
                          workflow.draft.steps,
                          path,
                          conn.method
                        )

                    handle_trigger(conn, workflow, scope, config, :preview, true)

                  {:error, _reason} ->
                    send_error(conn, 404, "Test webhook is not enabled")
                end
              else
                send_error(conn, 403, "Access denied")
              end

            # Production mode checks
            workflow.status != :active ->
              send_error(conn, 403, "Workflow is not active")

            is_nil(workflow.published_version_id) ->
              send_error(conn, 400, "Workflow is not published")

            true ->
              if Scope.can_view_workflow?(scope, workflow) do
                # If we didn't get config from registry (e.g. legacy ID lookup), fetch it now
                config =
                  config ||
                    (
                      workflow = Repo.preload(workflow, :published_version)

                      webhook_config_for(
                        workflow.published_version.steps,
                        path,
                        conn.method
                      )
                    )

                handle_trigger(conn, workflow, scope, config, :production)
              else
                send_error(conn, 404, "Workflow not found")
              end
          end
      end
    end
  end

  defp webhook_config_for(steps, path, method) do
    normalized_path = normalize_path(path)
    normalized_method = normalize_method(method)

    step =
      Enum.find(steps || [], fn step ->
        step.type_id == "webhook_trigger" &&
          normalize_path(Map.get(step.config, "path") || Map.get(step.config, :path) || step.id) ==
            normalized_path &&
          method_matches?(
            Map.get(step.config, "http_method") || Map.get(step.config, :http_method),
            normalized_method
          )
      end)

    if step, do: step.config || %{}, else: %{}
  end

  defp handle_trigger(conn, workflow, scope, config, execution_type, test_webhook? \\ false) do
    response_mode =
      Map.get(config, "response_mode") || Map.get(config, :response_mode) || "immediate"

    # 1. Extract payload
    payload = %{
      "body" => conn.body_params,
      "params" => conn.params,
      "headers" => Enum.into(conn.req_headers, %{}),
      "method" => conn.method
    }

    # 2. Create execution record base attributes
    attrs = %{
      workflow_id: workflow.id,
      execution_type: execution_type,
      trigger: %{
        "type" => "webhook",
        "data" => payload
      },
      metadata: %{
        "source" => "webhook",
        "remote_ip" => to_string(:inet.ntoa(conn.remote_ip))
      }
    }

    case response_mode do
      "on_respond_node" ->
        # Pass handler PID as ephemeral option
        case Executions.create_execution(scope, attrs) do
          {:ok, execution} ->
            _ = maybe_notify_webhook_test_execution(test_webhook?, workflow.id, execution.id)
            _ = maybe_disable_test_webhook(test_webhook?, workflow.id)

            # Start execution directly (do not use run_sync as it blocks)
            # Pass webhook_handler_pid to Server via Supervisor
            case Fizz.Runtime.Execution.Supervisor.start_execution(execution.id,
                   webhook_handler_pid: self()
                 ) do
              {:ok, pid} ->
                monitor_ref = Process.monitor(pid)
                wait_for_response(conn, monitor_ref, execution.id)

              {:error, {:already_started, pid}} ->
                monitor_ref = Process.monitor(pid)
                wait_for_response(conn, monitor_ref, execution.id)

              {:error, reason} ->
                handle_creation_error(conn, reason)
            end

          {:error, reason} ->
            handle_creation_error(conn, reason)
        end

      "on_completion" ->
        case Executions.create_execution(scope, attrs) do
          {:ok, execution} ->
            _ = maybe_notify_webhook_test_execution(test_webhook?, workflow.id, execution.id)
            _ = maybe_disable_test_webhook(test_webhook?, workflow.id)
            ExecutionWorker.run_sync(execution.id)
            # Re-fetch to get output
            execution = Repo.get!(Fizz.Executions.Execution, execution.id)

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(execution.output || %{}))

          {:error, reason} ->
            handle_creation_error(conn, reason)
        end

      _ ->
        # "immediate" or default
        case Executions.create_execution(scope, attrs) do
          {:ok, execution} ->
            _ = maybe_notify_webhook_test_execution(test_webhook?, workflow.id, execution.id)
            _ = maybe_disable_test_webhook(test_webhook?, workflow.id)
            ExecutionWorker.enqueue(execution.id)

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(
              202,
              Jason.encode!(%{
                status: "accepted",
                execution_id: execution.id
              })
            )

          {:error, reason} ->
            handle_creation_error(conn, reason)
        end
    end
  end

  defp maybe_disable_test_webhook(true, workflow_id) do
    _ = EditSessionServer.disable_test_webhook(workflow_id)
    :ok
  end

  defp maybe_disable_test_webhook(false, _workflow_id), do: :ok

  defp maybe_notify_webhook_test_execution(true, workflow_id, execution_id) do
    _ = EditSessionServer.notify_webhook_test_execution(workflow_id, execution_id)
    :ok
  end

  defp maybe_notify_webhook_test_execution(false, _workflow_id, _execution_id), do: :ok

  defp normalize_path(nil), do: nil

  defp normalize_path(path) when is_binary(path) do
    path
    |> String.trim()
    |> String.trim_leading("/")
    |> String.trim_trailing("/")
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_method(nil), do: "POST"

  defp normalize_method(method) when is_binary(method) do
    method
    |> String.trim()
    |> case do
      "" -> "POST"
      trimmed -> String.upcase(trimmed)
    end
  end

  defp method_matches?(configured_method, incoming_method) do
    normalized_config = normalize_method(configured_method)
    normalized_incoming = normalize_method(incoming_method)

    normalized_config == "ANY" or normalized_config == normalized_incoming
  end

  defp handle_creation_error(conn, :access_denied) do
    send_error(conn, 403, "Access denied")
  end

  defp handle_creation_error(conn, :workflow_not_published) do
    send_error(conn, 400, "Workflow is not published")
  end

  defp handle_creation_error(conn, reason) do
    Logger.error("Failed to create execution for webhook: #{inspect(reason)}")
    send_error(conn, 500, "Internal error")
  end

  defp wait_for_response(conn, monitor_ref, _execution_id) do
    receive do
      {:webhook_response, data} ->
        # We got the response we wanted!
        Process.demonitor(monitor_ref, [:flush])

        conn
        |> put_resp_content_type(Map.get(data, :content_type, "application/json"))
        |> send_resp(Map.get(data, :status, 200), Jason.encode!(Map.get(data, :body, %{})))

      {:DOWN, ^monitor_ref, :process, _pid, _reason} ->
        # Process died before sending response
        send_error(conn, 502, "Workflow completed without sending a response")
    after
      30_000 ->
        Process.demonitor(monitor_ref, [:flush])
        send_error(conn, 504, "Workflow timed out waiting for response")
    end
  end

  defp send_error(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{errors: %{detail: message}}))
    |> halt()
  end
end
