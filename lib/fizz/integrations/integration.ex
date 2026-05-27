defmodule Fizz.Integrations.Integration do
  @moduledoc """
  Behaviour for product-level integrations.

  Provider modules own authentication. Integration modules own product/domain
  grouping: executable step modules, catalog action IDs, triggers, required
  scopes, and shared helpers.
  """

  @callback id() :: String.t()
  @callback display_name() :: String.t()
  @callback provider_id() :: String.t() | nil
  @callback actions() :: [String.t()]
  @callback triggers() :: [module()]
  @callback step_modules() :: [module()]
  @callback required_scopes(operation :: atom()) :: [String.t()]
end
