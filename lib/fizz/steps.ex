defmodule Fizz.Steps do
  @moduledoc """
  Public API for step types.

  Step types are templates/blueprints that define what steps users can add to workflows.
  Each type specifies configuration schemas, input/output schemas, and the executor
  module that implements the actual logic.

  ## Architecture

  - Types are defined as code in executor modules using `Fizz.Steps.Definition`
  - The `Fizz.Steps.Registry` loads all types at startup and provides fast lookups
  - Workflows reference types by ID (e.g., "http_request") in their step definitions

  ## Example

      # Get all available step types
      types = Fizz.Steps.list_types()

      # Get a specific type
      {:ok, http_type} = Fizz.Steps.get_type("http_request")

      # Group types by category for UI
      grouped = Fizz.Steps.types_by_category()
  """

  alias Fizz.Steps.{Registry, Type}

  @doc """
  Returns all registered step types.
  """
  @spec list_types() :: [Type.t()]
  defdelegate list_types, to: Registry, as: :all

  @doc """
  Gets a step type by ID.

  ## Examples

      {:ok, type} = Fizz.Steps.get_type("http_request")
      {:error, :not_found} = Fizz.Steps.get_type("nonexistent")
  """
  @spec get_type(String.t()) :: {:ok, Type.t()} | {:error, :not_found}
  defdelegate get_type(type_id), to: Registry, as: :get

  @doc """
  Gets a step type by ID or raises if not found.
  """
  @spec get_type!(String.t()) :: Type.t()
  defdelegate get_type!(type_id), to: Registry, as: :get!

  @doc """
  Checks if a step type exists.
  """
  @spec type_exists?(String.t()) :: boolean()
  defdelegate type_exists?(type_id), to: Registry, as: :exists?

  @doc """
  Returns step types grouped by category.

  Useful for building the step palette in the UI.

  ## Example

      %{
        "Integrations" => [%Type{id: "http_request", ...}],
        "Data" => [%Type{id: "transform", ...}, %Type{id: "format", ...}],
        ...
      }
  """
  @spec types_by_category() :: %{String.t() => [Type.t()]}
  defdelegate types_by_category, to: Registry, as: :grouped_by_category

  @doc """
  Returns all unique category names.
  """
  @spec categories() :: [String.t()]
  defdelegate categories, to: Registry

  @doc """
  Lists step types filtered by category.
  """
  @spec list_types_by_category(String.t()) :: [Type.t()]
  defdelegate list_types_by_category(category), to: Registry, as: :list_by_category

  @doc """
  Lists step types filtered by kind.

  ## Examples

      Fizz.Steps.list_types_by_kind(:action)
      Fizz.Steps.list_types_by_kind(:trigger)
      Fizz.Steps.list_types_by_kind(:transform)
      Fizz.Steps.list_types_by_kind(:control_flow)
  """
  @spec list_types_by_kind(Type.step_kind()) :: [Type.t()]
  defdelegate list_types_by_kind(kind), to: Registry, as: :list_by_kind

  @doc """
  Returns the count of registered step types.
  """
  @spec type_count() :: non_neg_integer()
  defdelegate type_count, to: Registry, as: :count

  @doc """
  Returns step types formatted for the node library UI.
  """
  @spec list_library_items() :: [map()]
  defdelegate list_library_items, to: Registry, as: :library_items

  @doc """
  Validates that all step type IDs in a workflow exist.

  Returns `:ok` if all types exist, or `{:error, missing_ids}` with a list
  of type IDs that were not found.
  """
  @spec validate_type_ids([String.t()]) :: :ok | {:error, [String.t()]}
  def validate_type_ids(type_ids) when is_list(type_ids) do
    missing =
      type_ids
      |> Enum.uniq()
      |> Enum.reject(&type_exists?/1)

    case missing do
      [] -> :ok
      ids -> {:error, ids}
    end
  end
end
