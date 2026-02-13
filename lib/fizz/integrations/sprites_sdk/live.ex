defmodule Fizz.Integrations.SpritesSDK.Live do
  @moduledoc """
  Production adapter backed by the `Sprites` dependency.
  """

  @behaviour Fizz.Integrations.SpritesSDK

  @impl true
  def new(token, opts), do: Sprites.new(token, opts)

  @impl true
  def sprite(client, name), do: Sprites.sprite(client, name)

  @impl true
  def list(client, opts), do: Sprites.list(client, opts)

  @impl true
  def get_sprite(client, name), do: Sprites.get_sprite(client, name)

  @impl true
  def create(client, name, opts), do: Sprites.create(client, name, opts)

  @impl true
  def destroy(sprite), do: Sprites.destroy(sprite)

  @impl true
  def cmd(sprite, command, args, opts), do: Sprites.cmd(sprite, command, args, opts)

  @impl true
  def spawn(sprite, command, args, opts), do: Sprites.spawn(sprite, command, args, opts)

  @impl true
  def attach_session(sprite, session_id, opts),
    do: Sprites.attach_session(sprite, session_id, opts)

  @impl true
  def list_sessions(sprite), do: Sprites.list_sessions(sprite)

  @impl true
  def list_checkpoints(sprite, opts), do: Sprites.list_checkpoints(sprite, opts)

  @impl true
  def create_checkpoint(sprite, opts), do: Sprites.create_checkpoint(sprite, opts)

  @impl true
  def restore_checkpoint(sprite, checkpoint_id),
    do: Sprites.restore_checkpoint(sprite, checkpoint_id)

  @impl true
  def write(command, data), do: Sprites.write(command, data)

  @impl true
  def close_stdin(command), do: Sprites.close_stdin(command)

  @impl true
  def resize(command, rows, cols), do: Sprites.resize(command, rows, cols)

  @impl true
  def await(command, timeout), do: Sprites.await(command, timeout)
end
