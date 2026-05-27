defmodule Fizz.Steps.Type do
  @moduledoc """
  A Step Type is a template/blueprint for steps users can add to workflows.

  Examples: "HTTP Request", "Transform", "Postgres Query", "If/Else", etc.

  Each type defines:
  - Configuration schema (what the user configures in the UI)
  - Input/Output schemas (for validation and UI hints)
  - An executor module that implements the actual logic

  ## Usage

  Step types are defined using `Fizz.Steps.Definition` in executor modules
  and registered in `Fizz.Steps.Registry` at startup.

  To get a step type:

      {:ok, type} = Fizz.Steps.Registry.get("http_request")

  To list all types:

      types = Fizz.Steps.Registry.all()
  """

  @type step_kind :: :action | :trigger | :control_flow | :transform
  @type node_role :: :root | :subnode

  @type t :: %__MODULE__{
          id: String.t(),
          version: pos_integer(),
          name: String.t(),
          category: String.t(),
          description: String.t(),
          icon: String.t(),
          provider: String.t() | nil,
          integration: String.t() | nil,
          node_role: node_role(),
          fields: [Fizz.Fields.Definition.t()],
          config_schema: map(),
          default_config: map(),
          input_schema: map(),
          output_schema: map(),
          subnode_inputs: [map()],
          retry: Fizz.Workflows.RetryPolicy.t(),
          executor: String.t(),
          step_kind: step_kind(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @derive {LiveVue.Encoder,
           only: [
             :id,
             :version,
             :name,
             :category,
             :description,
             :icon,
             :provider,
             :integration,
             :node_role,
             :step_kind,
             :executor,
             :default_config,
             :config_schema,
             :input_schema,
             :output_schema,
             :subnode_inputs
           ]}
  @enforce_keys [:id, :name, :category, :description, :icon, :executor, :step_kind]
  defstruct [
    :id,
    :version,
    :name,
    :category,
    :description,
    :icon,
    :provider,
    :integration,
    :executor,
    :step_kind,
    :inserted_at,
    :updated_at,
    fields: [],
    node_role: :root,
    config_schema: %{},
    default_config: %{},
    input_schema: %{},
    output_schema: %{},
    subnode_inputs: [],
    retry: %Fizz.Workflows.RetryPolicy{}
  ]

  @doc """
  Converts the executor string to a module atom.
  Returns `{:ok, module}` or `{:error, reason}`.
  """
  def executor_module(%__MODULE__{executor: executor}) when is_binary(executor) do
    module =
      if String.starts_with?(executor, "Elixir.") do
        String.to_existing_atom(executor)
      else
        String.to_existing_atom("Elixir." <> executor)
      end

    {:ok, module}
  rescue
    ArgumentError -> {:error, :module_not_loaded}
  end

  def executor_module(%__MODULE__{executor: nil}), do: {:error, :no_executor}

  @doc """
  Converts the executor string to a module atom or raises.
  """
  def executor_module!(%__MODULE__{} = type) do
    case executor_module(type) do
      {:ok, module} -> module
      {:error, reason} -> raise "Failed to get executor module: #{inspect(reason)}"
    end
  end

  @doc """
  Returns true if this is a trigger step type.
  """
  def trigger?(%__MODULE__{step_kind: :trigger}), do: true
  def trigger?(%__MODULE__{}), do: false

  @doc """
  Returns true if this is a control flow step type (if/else, switch, loop, etc.).
  """
  def control_flow?(%__MODULE__{step_kind: :control_flow}), do: true
  def control_flow?(%__MODULE__{}), do: false

  @doc """
  Returns true if this is an action step type.
  """
  def action?(%__MODULE__{step_kind: :action}), do: true
  def action?(%__MODULE__{}), do: false

  @doc """
  Returns true if this is a transform step type.
  """
  def transform?(%__MODULE__{step_kind: :transform}), do: true
  def transform?(%__MODULE__{}), do: false
end
