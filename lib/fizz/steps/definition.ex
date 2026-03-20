defmodule Fizz.Steps.Definition do
  @moduledoc """
  Macro for declaring step type definitions within executor modules.

  This keeps step metadata, schemas, and executor behaviour co-located with
  the executor implementation. It also injects the helper functions consumed by
  `Fizz.Steps.Registry` and validates required metadata at compile time.

  ## Usage

      defmodule Fizz.Steps.Executors.HttpRequest do
        use Fizz.Steps.Definition,
          id: "http_request",
          name: "HTTP Request",
          category: "Integrations",
          description: "Make HTTP requests to external APIs",
          icon: "hero-globe-alt",
          kind: :action

        # Define schemas as module attributes
        @config_schema %{
          "type" => "object",
          "required" => ["url"],
          "properties" => %{
            "url" => %{"type" => "string", "title" => "URL"}
          }
        }

        @input_schema %{"type" => "object"}
        @output_schema %{"type" => "object"}

        @behaviour Fizz.Steps.Executors.Behaviour

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
  - `:role` (optional) - One of :root, :subnode (default: :root)

  ## Definition Attributes

  After `use`, you can redefine these module attributes:

  - `@config_schema` - JSON Schema for step configuration (what users fill in)
  - `@default_config` - Default configuration map (optional)
  - `@input_schema` - JSON Schema describing expected input
  - `@output_schema` - JSON Schema describing output
  - `@subnode_slots` - Slot declarations accepted by root nodes (optional)

  The macro defaults these attributes to:

  - `@config_schema` - `%{"type" => "object", "properties" => %{}}`
  - `@default_config` - `%{}`
  - `@input_schema` - `%{"type" => "object"}`
  - `@output_schema` - `%{"type" => "object"}`
  - `@subnode_slots` - `[]`
  """

  @required_opts [:id, :name, :category, :description, :icon, :kind]
  @valid_kinds [:action, :trigger, :control_flow, :transform]
  @valid_roles [:root, :subnode]

  defmacro __using__(opts) do
    # Validate required options at compile time
    for key <- @required_opts do
      unless Keyword.has_key?(opts, key) do
        raise ArgumentError, "#{key} is required for Fizz.Steps.Definition"
      end
    end

    kind = Keyword.fetch!(opts, :kind)
    role = Keyword.get(opts, :role, :root)

    unless kind in @valid_kinds do
      raise ArgumentError, "kind must be one of #{inspect(@valid_kinds)}, got: #{inspect(kind)}"
    end

    unless role in @valid_roles do
      raise ArgumentError, "role must be one of #{inspect(@valid_roles)}, got: #{inspect(role)}"
    end

    quote do
      @before_compile Fizz.Steps.Definition

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
      Module.register_attribute(__MODULE__, :step_role, persist: true)

      @step_id unquote(opts[:id])
      @step_name unquote(opts[:name])
      @step_category unquote(opts[:category])
      @step_description unquote(opts[:description])
      @step_icon unquote(opts[:icon])
      @step_kind unquote(opts[:kind])
      @step_role unquote(role)

      # Default schemas (can be overridden)
      @config_schema %{"type" => "object", "properties" => %{}}
      @default_config %{}
      @input_schema %{"type" => "object"}
      @output_schema %{"type" => "object"}
      @subnode_slots []

      # Allow redefinition
      Module.register_attribute(__MODULE__, :config_schema, accumulate: false)
      Module.register_attribute(__MODULE__, :default_config, accumulate: false)
      Module.register_attribute(__MODULE__, :input_schema, accumulate: false)
      Module.register_attribute(__MODULE__, :output_schema, accumulate: false)
      Module.register_attribute(__MODULE__, :subnode_slots, accumulate: false)

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
        %Fizz.Steps.Type{
          id: @step_id,
          name: @step_name,
          category: @step_category,
          description: @step_description,
          icon: @step_icon,
          node_role: @step_role,
          step_kind: @step_kind,
          executor: Atom.to_string(__MODULE__),
          config_schema: @config_schema,
          input_schema: @input_schema,
          output_schema: @output_schema,
          subnode_slots: @subnode_slots,
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
        @default_config
      end

      defoverridable default_config: 0
    end
  end
end
