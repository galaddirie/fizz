defmodule Fizz.Sprites.Console.Registry do
  @moduledoc """
  Registry helpers for sprite console runtime processes.
  """

  @registry Fizz.Sprites.Console.Registry

  @spec via(String.t()) :: {:via, Registry, {module(), String.t()}}
  def via(session_id) when is_binary(session_id) do
    {:via, Registry, {@registry, session_id}}
  end

  @spec whereis(String.t()) :: pid() | nil
  def whereis(session_id) when is_binary(session_id) do
    case Registry.lookup(@registry, session_id) do
      [{pid, _value}] -> pid
      _ -> nil
    end
  end

  @spec list_session_ids() :: [String.t()]
  def list_session_ids do
    Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end
end
