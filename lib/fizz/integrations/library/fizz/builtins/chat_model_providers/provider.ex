defmodule Fizz.Integrations.Library.Fizz.Builtins.ChatModelProviders.Provider do
  @moduledoc false

  @callback provider_prefix() :: String.t()
  @callback generate(request :: map(), context :: map()) :: {:ok, map()} | {:error, term()}
end
