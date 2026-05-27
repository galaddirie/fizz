defmodule Fizz.Integrations.Integration do
  @moduledoc """
  Behaviour for product-level integrations.

  Provider modules own authentication. Integration modules own the external
  product surface area: actions, triggers, required scopes, and shared helpers.
  """

  @callback id() :: String.t()
  @callback display_name() :: String.t()
  @callback provider_id() :: String.t()
  @callback actions() :: [String.t()]
  @callback triggers() :: [module()]
  @callback required_scopes(operation :: atom()) :: [String.t()]
end
