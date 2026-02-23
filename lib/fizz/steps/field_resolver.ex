defmodule Fizz.Steps.FieldResolver do
  @moduledoc """
  Routes LiveView search queries from generic frontend components
  to the appropriate domain context or step executor.
  """

  @type resolver_args :: %{
          optional(:q) => String.t(),
          optional(:params) => map(),
          optional(:context) => map()
        }

  @doc """
  Resolves the given `resolver_name` with `args`, returning a list of options.
  """
  @spec resolve(String.t(), resolver_args()) :: {:ok, [map()]} | {:error, term()}
  def resolve("credentials", %{q: q, params: params, context: context}) do
    Fizz.Integrations.CredentialsResolver.search(q, params, context)
  end

  def resolve(resolver_name, _args) do
    {:error, {:unknown_resolver, resolver_name}}
  end
end
