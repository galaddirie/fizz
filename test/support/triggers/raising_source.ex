defmodule Fizz.Triggers.RaisingSource do
  @moduledoc false

  @behaviour Fizz.Triggers.Source

  @impl true
  def source_key(_params, _context), do: "test:raising-source"

  @impl true
  def init_cursor(_params, _context), do: {:ok, %{"initialized" => false}}

  @impl true
  def poll(_params, _cursor, _context) do
    if pid = Process.whereis(Fizz.Triggers.RaisingSourceTest) do
      send(pid, {:raising_source_polled, self()})
    end

    raise "raising source poll failed"
  end

  @impl true
  def commit(_params, _checkpoint, _context), do: :ok

  @impl true
  def event_id(event), do: event["id"]
end
