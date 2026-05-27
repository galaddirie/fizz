defmodule Fizz.Integrations.ExternalStepsTest do
  use Fizz.IntegrationStepCase, async: true

  alias Fizz.Integrations.Registry, as: IntegrationRegistry
  alias Fizz.Integrations.StepRegistry, as: StepRegistry

  @expected_integrations [
    {"anthropic", "anthropic_api_key", ["anthropic_vision_analysis"]},
    {"box", "box_oauth", ["box_upload_file"]},
    {"github", "github_oauth", ["github_create_issue", "github_create_pr"]},
    {"gmail", "google_oauth", ["gmail_send_email", "gmail_reply_email"]},
    {"google_docs", "google_oauth", ["google_docs_create_doc", "google_docs_append_text"]},
    {"google_drive", "google_oauth", ["google_drive_upload_file"]},
    {"google_slides", "google_oauth",
     ["google_slides_create_presentation", "google_slides_add_slide"]},
    {"notion", "notion_oauth", ["notion_create_page", "notion_update_page"]},
    {"onedrive", "microsoft_oauth", ["onedrive_upload_file"]},
    {"openai", "openai_api_key", ["openai_image_generation"]},
    {"outlook", "microsoft_oauth", ["outlook_send_email"]},
    {"powerpoint", "microsoft_oauth", ["powerpoint_create_presentation"]},
    {"sharepoint", "microsoft_oauth", ["sharepoint_upload_file"]},
    {"slack", "slack_oauth", ["slack_send_message", "slack_create_channel"]},
    {"teams", "microsoft_oauth", ["teams_send_message"]}
  ]

  @external_support_steps [
    {"anthropic_model", "anthropic_api_key", "anthropic"},
    {"gmail_trigger", "google_oauth", "gmail"},
    {"github_trigger", "github_oauth", "github"},
    {"google_docs_trigger", "google_oauth", "google_docs"},
    {"google_sheets_trigger", "google_oauth", "google_sheets"},
    {"notion_trigger", "notion_oauth", "notion"},
    {"openai_model", "openai_api_key", "openai"},
    {"outlook_trigger", "microsoft_oauth", "outlook"},
    {"slack_trigger", "slack_oauth", "slack"},
    {"teams_trigger", "microsoft_oauth", "teams"}
  ]

  @placeholder_steps [
    {"anthropic_vision_analysis", "anthropic_api_key", "anthropic"},
    {"box_upload_file", "box_oauth", "box"},
    {"github_create_issue", "github_oauth", "github"},
    {"github_create_pr", "github_oauth", "github"},
    {"gmail_reply_email", "google_oauth", "gmail"},
    {"gmail_send_email", "google_oauth", "gmail"},
    {"gmail_trigger", "google_oauth", "gmail"},
    {"google_docs_append_text", "google_oauth", "google_docs"},
    {"google_docs_create_doc", "google_oauth", "google_docs"},
    {"google_docs_trigger", "google_oauth", "google_docs"},
    {"google_drive_upload_file", "google_oauth", "google_drive"},
    {"google_slides_add_slide", "google_oauth", "google_slides"},
    {"google_slides_create_presentation", "google_oauth", "google_slides"},
    {"notion_create_page", "notion_oauth", "notion"},
    {"notion_trigger", "notion_oauth", "notion"},
    {"notion_update_page", "notion_oauth", "notion"},
    {"onedrive_upload_file", "microsoft_oauth", "onedrive"},
    {"openai_image_generation", "openai_api_key", "openai"},
    {"outlook_send_email", "microsoft_oauth", "outlook"},
    {"outlook_trigger", "microsoft_oauth", "outlook"},
    {"powerpoint_create_presentation", "microsoft_oauth", "powerpoint"},
    {"sharepoint_upload_file", "microsoft_oauth", "sharepoint"},
    {"slack_create_channel", "slack_oauth", "slack"},
    {"slack_send_message", "slack_oauth", "slack"},
    {"slack_trigger", "slack_oauth", "slack"},
    {"teams_send_message", "microsoft_oauth", "teams"},
    {"teams_trigger", "microsoft_oauth", "teams"}
  ]

  @fizz_step_ids [
    "aggregator",
    "ai_agent",
    "ai_structure_schema",
    "ai_tool_http",
    "condition",
    "data_filter",
    "data_output",
    "data_transform",
    "debug",
    "format",
    "http_request",
    "join",
    "json_parser",
    "manual_input",
    "math",
    "on_chat_trigger",
    "schedule_trigger",
    "splitter",
    "switch",
    "wait"
  ]

  describe "product integration catalog entries" do
    test "static external integrations expose action step type IDs and step modules" do
      for {integration_id, provider_id, action_ids} <- @expected_integrations do
        assert {:ok, integration} = IntegrationRegistry.get(integration_id)

        assert integration.provider_id == provider_id
        assert integration.actions == action_ids
        assert integration.step_modules != []

        for step_id <- action_ids do
          step_type = step_type!(step_id)

          assert step_type.provider == provider_id
          assert step_type.integration == integration_id
        end
      end
    end

    test "the Fizz integration owns providerless built-in step modules" do
      assert {:ok, integration} = IntegrationRegistry.get("fizz")

      assert integration.provider_id == nil

      assert integration.step_modules |> Enum.map(& &1.__step_id__()) |> Enum.sort() ==
               @fizz_step_ids

      for step_id <- @fizz_step_ids do
        step_type = step_type!(step_id)
        assert {:ok, module} = StepType.executor_module(step_type)

        refute step_type.provider
        assert step_type.integration == "fizz"

        assert module
               |> Atom.to_string()
               |> String.starts_with?("Elixir.Fizz.Integrations.Fizz.Builtins.")
      end
    end

    test "provider-owned trigger and subnode steps declare catalog ownership" do
      for {step_id, provider_id, integration_id} <- @external_support_steps do
        step_type = step_type!(step_id)

        assert step_type.provider == provider_id
        assert step_type.integration == integration_id
      end
    end

    test "every registered step declares an integration owner" do
      for step_type <- StepRegistry.all() do
        assert is_binary(step_type.integration)
        assert step_type.integration != ""
      end
    end

    test "provider-owned step executors live under integration namespaces" do
      for step_type <- StepRegistry.all(), is_binary(step_type.provider) do
        assert {:ok, module} = StepType.executor_module(step_type)

        module_name = Atom.to_string(module)

        assert String.starts_with?(module_name, "Elixir.Fizz.Integrations.")
        refute String.starts_with?(module_name, "Elixir.Fizz.Integrations.Fizz.")
      end
    end
  end

  describe "placeholder external executors" do
    test "skeleton steps return a typed not-implemented payload" do
      for {step_id, provider_id, integration_id} <- @placeholder_steps do
        assert {:ok, result} = execute_step(step_id)

        assert %{
                 "status" => "not_implemented",
                 "step_type_id" => ^step_id,
                 "provider" => ^provider_id,
                 "integration" => ^integration_id
               } = result

        assert is_binary(result["message"])
      end
    end
  end
end
