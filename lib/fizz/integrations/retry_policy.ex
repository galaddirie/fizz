defmodule Fizz.Integrations.RetryPolicy do
  @moduledoc """
  Declarative retry metadata for an integration operation.
  """

  defstruct max_attempts: 1, backoff: :none

  @type backoff :: :none | :linear | :exponential
  @type t :: %__MODULE__{max_attempts: pos_integer(), backoff: backoff()}
end
