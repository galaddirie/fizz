defmodule Fizz.Integrations.Operation do
  @moduledoc """
  Behaviour for integration operations.

  Step executors should delegate product-specific API work to operation modules
  so UI metadata, workflow steps, and provider transport do not collapse into a
  single module as the integration catalog grows.
  """

  @callback id() :: String.t()
  @callback schema() :: map()
  @callback execute(config :: map(), input :: term(), context :: map()) ::
              {:ok, term()} | {:error, term()}
end
