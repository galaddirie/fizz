defimpl LiveVue.Encoder, for: Fizz.Accounts.Project do
  def encode(project, opts) do
    %{
      id: project.id,
      name: project.name,
      slug: project.slug,
      description: project.description,
      metadata: project.metadata,
      workos_organization_id: project.workos_organization_id,
      inserted_at: project.inserted_at,
      updated_at: project.updated_at
    }
    |> LiveVue.Encoder.encode(opts)
  end
end

defimpl LiveVue.Encoder, for: Fizz.Integrations.Steps.Type do
  def encode(type, opts) do
    %{
      id: type.id,
      version: type.version,
      name: type.name,
      category: type.category,
      description: type.description,
      icon: type.icon,
      provider: type.provider,
      integration: type.integration,
      step_kind: type.step_kind,
      executor: type.executor,
      default_config: type.default_config,
      config_schema: type.config_schema,
      input_schema: type.input_schema,
      output_schema: type.output_schema
    }
    |> LiveVue.Encoder.encode(opts)
  end
end

defimpl LiveVue.Encoder, for: Fizz.Workflows.DraftValidator.ValidationError do
  def encode(error, opts) do
    FizzWeb.WorkflowsLive.Payload.validation_error(error)
    |> LiveVue.Encoder.encode(opts)
  end
end
