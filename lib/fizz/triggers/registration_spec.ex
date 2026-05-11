defmodule Fizz.Triggers.RegistrationSpec do
  @moduledoc """
  Describes the external source listened to by a trigger executor.
  """

  @type kind :: :manual | :webhook | :schedule | :polling | :subscription | :chat

  @type t :: %__MODULE__{
          kind: kind(),
          params: map(),
          dedup_key: String.t() | nil,
          provider: String.t() | nil,
          source_module: module() | nil,
          source_key: String.t() | nil
        }

  defstruct [:kind, :params, :dedup_key, :provider, :source_module, :source_key]
end
