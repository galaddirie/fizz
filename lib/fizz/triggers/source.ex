defmodule Fizz.Triggers.Source do
  @moduledoc """
  Behaviour implemented by external trigger sources.

  A source is a shared external watch target, such as one Google Sheet for one
  credential. Many workflow trigger registrations may subscribe to a single
  source.
  """

  @callback source_key(params :: map(), context :: map()) :: String.t()
  @callback init_cursor(params :: map(), context :: map()) :: {:ok, map()} | {:error, term()}

  @callback poll(params :: map(), cursor :: map() | nil, context :: map()) ::
              {:ok, %{events: [map()], cursor: map() | nil}}
              | {:backoff, term()}
              | {:error, term()}

  @callback commit(params :: map(), checkpoint :: term(), context :: map()) ::
              :ok | {:error, term()}

  @callback event_id(event :: map()) :: String.t()

  @optional_callbacks commit: 3
end
