defmodule Fizz.Slots.Resolver do
  @moduledoc """
  Behaviour for slot kind resolvers.

  A slot kind resolver is responsible for three things:

    * `resolve/3` — at runtime, given a slot spec, the user's persisted binding
      data, and the run scope, produce the concrete value to inject into step
      execution (e.g. a fetched OAuth token).

    * `validate_binding_data/1` — at the moment a user submits a binding,
      verify that `binding_data` has the shape and content this kind requires.

    * `candidate_options/2` — for the run-launch UI, list the values this user
      may choose from for a slot with the given spec.
  """

  @type spec :: map()
  @type binding_data :: map() | nil
  @type scope :: map()

  @callback resolve(spec, binding_data, scope) :: {:ok, term()} | {:error, term()}
  @callback validate_binding_data(map()) :: :ok | {:error, term()}
  @callback candidate_options(spec, scope) :: {:ok, [map()]} | {:error, term()}
end
