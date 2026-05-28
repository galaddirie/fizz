defmodule Fizz.Integrations.Steps.Definition do
  @moduledoc """
  Macro for declaring step type definitions within executor modules.

  This keeps step metadata, schemas, and executor behaviour co-located with
  the executor implementation. It also injects the helper functions consumed by
  `Fizz.Integrations.Steps.Registry` and validates required metadata at compile time.

  ## Usage

      defmodule Fizz.Integrations.Library.Fizz.Builtins.HttpRequest do
        use Fizz.Integrations.Steps.Definition,
          id: "http_request",
          name: "HTTP Request",
          category: "Integrations",
          description: "Make HTTP requests to external APIs",
          icon: "hero-globe-alt",
          kind: :action,
          integration: "fizz"

        alias Fizz.Fields

        @fields [
          Fields.string("url", label: "URL", required?: true)
        ]

        @input_schema %{"type" => "object"}
        @output_schema %{"type" => "object"}

        @behaviour Fizz.Workflows.StepExecutor

        @impl true
        def execute(config, input, context) do
          # ... implementation
        end
      end

  ## Options

  - `:id` (required) - Unique identifier for the step type (snake_case)
  - `:name` (required) - Human-readable display name
  - `:category` (required) - Category for grouping in the UI
  - `:description` (required) - Description of what the step does
  - `:icon` (required) - Icon identifier (Heroicon name like "hero-globe-alt" or static path like "/images/openai.svg")
  - `:kind` (required) - One of :action, :trigger, :control_flow, :transform
  - `:provider` (optional) - Provider ID for integration-owned steps
  - `:integration` (optional) - Integration ID for integration-owned steps
  - `:version` (optional) - Step definition version (default: 1)

  ## Definition Attributes

  After `use`, you can redefine these module attributes:

  - `@fields` - Typed field definitions for step configuration
  - `@retry` - Durable retry policy for runtime errors
  - `@input_schema` - JSON Schema describing expected input
  - `@output_schema` - JSON Schema describing output

  The macro defaults these attributes to:

  - `@fields` - `[]`
  - `@retry` - `%Fizz.Workflows.RetryPolicy{}`
  - `@input_schema` - `%{"type" => "object"}`
  - `@output_schema` - `%{"type" => "object"}`
  """

  @required_opts [:id, :name, :category, :description, :icon, :kind]
  @valid_kinds [:action, :trigger, :control_flow, :transform]

  defmacro __using__(opts) do
    # Validate required options at compile time
    for key <- @required_opts do
      unless Keyword.has_key?(opts, key) do
        raise ArgumentError, "#{key} is required for Fizz.Integrations.Steps.Definition"
      end
    end

    kind = Keyword.fetch!(opts, :kind)
    provider = Keyword.get(opts, :provider)
    integration = Keyword.get(opts, :integration)
    version = Keyword.get(opts, :version, 1)

    unless kind in @valid_kinds do
      raise ArgumentError, "kind must be one of #{inspect(@valid_kinds)}, got: #{inspect(kind)}"
    end

    quote do
      @before_compile Fizz.Integrations.Steps.Definition

      if unquote(kind) == :trigger do
        @behaviour Fizz.Triggers.Behaviour
      end

      # Store the definition metadata
      Module.register_attribute(__MODULE__, :step_id, persist: true)
      Module.register_attribute(__MODULE__, :step_name, persist: true)
      Module.register_attribute(__MODULE__, :step_category, persist: true)
      Module.register_attribute(__MODULE__, :step_description, persist: true)
      Module.register_attribute(__MODULE__, :step_icon, persist: true)
      Module.register_attribute(__MODULE__, :step_kind, persist: true)
      Module.register_attribute(__MODULE__, :step_provider, persist: true)
      Module.register_attribute(__MODULE__, :step_integration, persist: true)
      Module.register_attribute(__MODULE__, :step_version, persist: true)

      @step_id unquote(opts[:id])
      @step_name unquote(opts[:name])
      @step_category unquote(opts[:category])
      @step_description unquote(opts[:description])
      @step_icon unquote(opts[:icon])
      @step_kind unquote(opts[:kind])
      @step_provider unquote(provider)
      @step_integration unquote(integration)
      @step_version unquote(version)

      # Default declarations (can be overridden)
      @fields []
      @retry %Fizz.Workflows.RetryPolicy{}
      @input_schema %{"type" => "object"}
      @output_schema %{"type" => "object"}

      # Allow redefinition
      Module.register_attribute(__MODULE__, :fields, accumulate: false)
      Module.register_attribute(__MODULE__, :retry, accumulate: false)
      Module.register_attribute(__MODULE__, :input_schema, accumulate: false)
      Module.register_attribute(__MODULE__, :output_schema, accumulate: false)

      if unquote(kind) == :trigger do
        @impl true
        def registration_spec(_config, _context), do: {:error, :not_implemented}

        @impl true
        def match?(_config, _incoming_event), do: true

        @impl true
        def normalize_event(_config, raw_event) when is_map(raw_event), do: {:ok, raw_event}

        defoverridable registration_spec: 2, match?: 2, normalize_event: 2
      end
    end
  end

  defmacro __before_compile__(_env) do
    quote do
      @doc """
      Returns the step type definition struct for this executor.
      """
      def __step_definition__ do
        fields = Fizz.Fields.validate!(@fields)

        %Fizz.Integrations.Steps.Type{
          id: @step_id,
          version: @step_version,
          name: @step_name,
          category: @step_category,
          description: @step_description,
          icon: @step_icon,
          provider: @step_provider,
          integration: @step_integration,
          step_kind: @step_kind,
          executor: Atom.to_string(__MODULE__),
          fields: fields,
          config_schema: Fizz.Fields.to_schema(fields),
          default_config: Fizz.Fields.defaults(fields),
          input_schema: @input_schema,
          output_schema: @output_schema,
          retry: Fizz.Workflows.RetryPolicy.validate!(@retry),
          inserted_at: nil,
          updated_at: nil
        }
      end

      @doc """
      Returns the step type ID.
      """
      def __step_id__, do: @step_id

      @doc """
      Returns the default configuration for this step type.
      """
      def default_config do
        Fizz.Fields.defaults(@fields)
      end

      defoverridable default_config: 0
    end
  end
end
