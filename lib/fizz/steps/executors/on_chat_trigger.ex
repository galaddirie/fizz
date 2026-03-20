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
  alias Fizz.Triggers.RegistrationSpec

  @impl true
  def registration_spec(config, _context) do
    {:ok,
     %RegistrationSpec{
       kind: :chat,
       params:
         %{
           "session_scope" => Map.get(config, "session_scope", "per_user"),
           "greeting" => Map.get(config, "greeting"),
           "input_schema" => Map.get(config, "input_schema")
         }
         |> Enum.reject(fn {_key, value} -> is_nil(value) end)
         |> Map.new()
     }}
  end

  @impl true
  def execute(_config, _input, _context) do
    # TODO: Implement chat trigger logic
    {:ok, %{}}
  end

  @impl true
  def normalize_event(_config, raw_event) when is_map(raw_event), do: {:ok, raw_event}
end
