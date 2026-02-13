defmodule Fizz.Integrations.SpritesSDK do
  @moduledoc """
  Behaviour for app-facing Sprites SDK operations.
  """

  @callback new(String.t(), keyword()) :: term()
  @callback sprite(term(), String.t()) :: term()
  @callback list(term(), keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback get_sprite(term(), String.t()) :: {:ok, map()} | {:error, term()}
  @callback create(term(), String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback destroy(term()) :: :ok | {:error, term()}
  @callback cmd(term(), String.t(), [String.t()], keyword()) :: {binary(), non_neg_integer()}

  @callback spawn(term(), String.t(), [String.t()], keyword()) ::
              {:ok, term()} | {:error, term()}

  @callback attach_session(term(), String.t(), keyword()) ::
              {:ok, term()} | {:error, term()}

  @callback list_sessions(term()) :: {:ok, [term()]} | {:error, term()}
  @callback list_checkpoints(term(), keyword()) :: {:ok, [term()]} | {:error, term()}

  @callback create_checkpoint(term(), keyword()) ::
              {:ok, Enumerable.t()} | {:error, term()}

  @callback restore_checkpoint(term(), String.t()) ::
              {:ok, Enumerable.t()} | {:error, term()}

  @callback write(term(), iodata()) :: :ok | {:error, term()}
  @callback close_stdin(term()) :: :ok
  @callback resize(term(), pos_integer(), pos_integer()) :: :ok
  @callback await(term(), timeout()) :: {:ok, non_neg_integer()} | {:error, term()}
end
