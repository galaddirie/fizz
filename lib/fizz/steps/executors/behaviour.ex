defmodule Fizz.Steps.Executors.Behaviour do
  @moduledoc """
  Behaviour for step executors.

  Each step type in the workflow system has an associated executor module that
  implements this behaviour. The executor is responsible for performing the
  actual work of the step given its configuration and input data.

  ## Example Implementation

      defmodule Fizz.Steps.Executors.HTTP do
        @behaviour Fizz.Steps.Executors.Behaviour

        @impl true
        def execute(config, _input, context) do
          url = config["url"]
          method = config["method"] || "GET"
          body = Map.get(config, "body")

          req_opts =
            if body do
              [method: method, url: url, json: body]
            else
              [method: method, url: url]
            end

          case Req.request(req_opts) do
            {:ok, %{status: status, body: body}} when status in 200..299 ->
              {:ok, %{"status" => status, "body" => body}}

            {:ok, %{status: status, body: body}} ->
              {:error, %{status: status, body: body}}

            {:error, reason} ->
              {:error, reason}
          end
        end

        @impl true
        def validate_config(config) do
          cond do
            not is_binary(config["url"]) ->
              {:error, [url: "is required and must be a string"]}

            true ->
              :ok
          end
        end
      end

  ## Return Values

  - `{:ok, output}` - The step executed successfully with the given output
  - `{:error, reason}` - The step failed with the given reason
  - `{:skip, reason}` - The step was skipped (e.g., condition not met)
  """

  @doc """
  Executes the step with the given configuration, input, and runtime context.

  ## Parameters

  - `config` - The step's configuration map (from `step.config`)
  - `input` - The input data flowing into this step (from parent steps)
  - `context` - The current runtime metadata map.

  ## Returns

  - `{:ok, output}` - Success with output data
  - `{:error, reason}` - Failure with error details
  - `{:skip, reason}` - Step was skipped
  """
  @callback execute(config :: map(), input :: term(), context :: map()) ::
              {:ok, output :: term()}
              | {:error, reason :: term()}
              | {:skip, reason :: term()}

  @doc """
  Validates the step's configuration.

  Called during workflow publishing to ensure step configurations are valid
  before the workflow can be executed.

  ## Parameters

  - `config` - The step's configuration map to validate

  ## Returns

  - `:ok` - Configuration is valid
  - `{:error, errors}` - Configuration is invalid with list of error tuples
  """
  @callback validate_config(config :: map()) :: :ok | {:error, errors :: list()}

  @doc """
  Returns the default configuration for this step type.

  This is called when a new step of this type is added to a workflow.
  It can return a static map or generate dynamic values (like UUIDs).
  """
  @callback default_config() :: map()

  @doc """
  Returns the effective output schema for a step configuration.

  This is used to refine output schemas based on user-provided configuration.
  """
  @callback effective_output_schema(config :: map()) :: map() | nil

  @optional_callbacks validate_config: 1, default_config: 0, effective_output_schema: 1

  # ============================================================================
  # Helper Functions
  # ============================================================================

  @doc """
  Resolves the executor module for a given step type ID.

  Returns `{:ok, module}` if found and loaded, `{:error, reason}` otherwise.
  """
  def resolve(type_id) when is_binary(type_id) do
    case Fizz.Steps.Registry.get(type_id) do
      {:ok, type} ->
        Fizz.Steps.Type.executor_module(type)

      {:error, :not_found} ->
        {:error, {:not_found, type_id}}
    end
  end

  @doc """
  Resolves the executor module or raises.
  """
  def resolve!(type_id) do
    case resolve(type_id) do
      {:ok, module} -> module
      {:error, reason} -> raise "Failed to resolve executor for #{type_id}: #{inspect(reason)}"
    end
  end

  @doc """
  Executes a step using its type ID to resolve the executor.

  This is a convenience function that combines resolution and execution.
  """
  def execute(type_id, config, input, context) do
    case resolve(type_id) do
      {:ok, module} ->
        module.execute(config, input, Map.put(context, :type_id, type_id))

      {:error, reason} ->
        {:error, {:executor_not_found, reason}}
    end
  end

  @doc """
  Validates config using the executor's validate_config callback if defined.
  """
  def validate_config(type_id, config) do
    case resolve(type_id) do
      {:ok, module} ->
        if function_exported?(module, :validate_config, 1) do
          module.validate_config(config)
        else
          :ok
        end

      {:error, _reason} ->
        # Can't validate if executor doesn't exist
        :ok
    end
  end
end
