defmodule Fizz.Workflows.DraftValidator do
  @moduledoc false

  alias Fizz.Accounts.Scope
  alias Fizz.Workflows.DraftValidator.ValidationError
  alias Fizz.Workflows.PublishValidation
  alias Fizz.Workflows.WorkflowDefinitionVersion

  defmodule ValidationError do
    @derive {Jason.Encoder, only: [:step_id, :field, :message, :severity, :code]}
    defstruct [:step_id, :field, :message, :severity, :code]

    @type t :: %__MODULE__{
            step_id: String.t() | nil,
            field: String.t() | nil,
            message: String.t(),
            severity: :error | :warning,
            code: atom()
          }
  end

  @spec validate_for_publish(WorkflowDefinitionVersion.t(), Scope.t()) ::
          :ok | {:error, [ValidationError.t()]}
  def validate_for_publish(%WorkflowDefinitionVersion{} = version, %Scope{} = _scope) do
    errors =
      version
      |> collect_errors()
      |> dedupe_errors()

    case errors do
      [] -> :ok
      _ -> {:error, errors}
    end
  end

  defp collect_errors(%WorkflowDefinitionVersion{} = version) do
    steps = version.steps || []
    connections = version.connections || []

    required_field_errors =
      wrap_errors(PublishValidation.required_field_issues(steps), :missing_required_field)

    invalid_step_config_errors =
      steps
      |> PublishValidation.step_config_issues()
      |> reject_missing_required_duplicates(required_field_errors)
      |> wrap_errors(:invalid_step_config)

    PublishValidation.has_entry_step_issues(steps, connections)
    |> wrap_errors(:missing_entry_step)
    |> Kernel.++(required_field_errors)
    |> Kernel.++(invalid_step_config_errors)
    |> Kernel.++(wrap_errors(PublishValidation.expression_issues(steps), :invalid_expression))
    |> Kernel.++(
      wrap_errors(
        PublishValidation.credential_declaration_issues(steps),
        :invalid_credential_declaration
      )
    )
    |> Kernel.++(
      wrap_errors(PublishValidation.trigger_root_issues(steps, connections), :trigger_not_root)
    )
    |> Kernel.++(wrap_errors(PublishValidation.cycle_issues(steps, connections), :cycle_detected))
  end

  defp wrap_errors(issues, code) when is_list(issues) and is_atom(code) do
    Enum.map(issues, fn issue ->
      %ValidationError{
        step_id: issue.step_id,
        field: issue.field,
        message: issue.message,
        severity: :error,
        code: code
      }
    end)
  end

  defp reject_missing_required_duplicates(step_config_issues, required_field_errors) do
    required_fields =
      required_field_errors
      |> Enum.reduce(MapSet.new(), fn %ValidationError{step_id: step_id, field: field}, acc ->
        MapSet.put(acc, {step_id, field})
      end)

    Enum.reject(step_config_issues, fn issue ->
      issue.message == "is required" and
        MapSet.member?(required_fields, {issue.step_id, issue.field})
    end)
  end

  defp dedupe_errors(errors) do
    errors
    |> Enum.uniq_by(fn %ValidationError{} = error ->
      {error.step_id, error.field, error.message, error.severity, error.code}
    end)
  end
end
