defmodule Fizz.Integrations.Library.Anthropic.ChatModelProvider do
  @moduledoc false

  @behaviour Fizz.Integrations.Library.Fizz.Builtins.ChatModelProviders.Provider

  @impl true
  def provider_prefix, do: "anthropic"

  @impl true
  def generate(_request, _context), do: {:error, :anthropic_chat_not_implemented}
end
