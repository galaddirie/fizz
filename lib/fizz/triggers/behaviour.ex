defmodule Fizz.Triggers.Behaviour do
  @moduledoc """
  Additional behaviour implemented by trigger step executors.
  """

  alias Fizz.Triggers.RegistrationSpec

  @callback registration_spec(config :: map(), context :: map()) ::
              {:ok, RegistrationSpec.t()} | {:error, term()}

  @callback match?(config :: map(), incoming_event :: map()) :: boolean()

  @callback normalize_event(config :: map(), raw_event :: map()) ::
              {:ok, map()} | {:error, term()}

  @optional_callbacks [match?: 2]
end
