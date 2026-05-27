defmodule Fizz.Workflows.CredentialDefaults do
  @moduledoc false

  alias Fizz.Fields.Credential
  alias Fizz.Integrations.StepRegistry, as: StepRegistry
  alias Fizz.Workflows.Embeds.Step
  alias Fizz.Workflows.WorkflowDefinitionVersion

  @spec normalize_version(WorkflowDefinitionVersion.t()) :: WorkflowDefinitionVersion.t()
  def normalize_version(%WorkflowDefinitionVersion{} = version) do
    %{version | steps: normalize_steps(version.steps || [])}
  end

  @spec normalize_snapshot_attrs(map()) :: map()
  def normalize_snapshot_attrs(attrs) when is_map(attrs) do
    cond do
      Map.has_key?(attrs, :steps) ->
        Map.update!(attrs, :steps, &normalize_steps/1)

      Map.has_key?(attrs, "steps") ->
        Map.update!(attrs, "steps", &normalize_steps/1)

      true ->
        attrs
    end
  end

  @spec normalize_steps(term()) :: term()
  def normalize_steps(steps) when is_list(steps), do: Enum.map(steps, &normalize_step/1)
  def normalize_steps(steps), do: steps

  defp normalize_step(%Step{} = step) do
    %{step | config: normalize_step_config(step.type_id, step.config || %{})}
  end

  defp normalize_step(%{type_id: type_id} = step) do
    Map.put(step, :config, normalize_step_config(type_id, step_config(step)))
  end

  defp normalize_step(%{"type_id" => type_id} = step) do
    Map.put(step, "config", normalize_step_config(type_id, step_config(step)))
  end

  defp normalize_step(step), do: step

  defp normalize_step_config(type_id, config) when is_binary(type_id) and is_map(config) do
    type_id
    |> credential_default_config()
    |> Enum.reduce(config, fn {field, declaration}, acc ->
      if missing_credential_value?(Map.get(acc, field)) do
        Map.put(acc, field, declaration)
      else
        acc
      end
    end)
  end

  defp normalize_step_config(_type_id, config), do: config

  defp credential_default_config(type_id) do
    type_id
    |> StepRegistry.get_default_config()
    |> Enum.filter(fn {_field, value} -> Credential.declaration?(value) end)
  end

  defp step_config(%Step{config: config}) when is_map(config), do: config
  defp step_config(%{config: config}) when is_map(config), do: config
  defp step_config(%{"config" => config}) when is_map(config), do: config
  defp step_config(_step), do: %{}

  defp missing_credential_value?(nil), do: true
  defp missing_credential_value?(_value), do: false
end
