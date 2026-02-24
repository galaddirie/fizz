defmodule Fizz.Steps.Executors.OnChatTrigger do
  @moduledoc """
  Trigger node that activates when a chat message is received.
  """
  use Fizz.Steps.Definition,
    id: "on_chat_trigger",
    name: "On Chat Trigger",
    category: "Triggers",
    description: "Activates when a chat message is received",
    icon: "hero-chat-bubble-left-right",
    kind: :trigger

  @behaviour Fizz.Steps.Executors.Behaviour

  @impl true
  def execute(_config, _input, _context) do
    # TODO: Implement chat trigger logic
    {:ok, %{}}
  end
end
