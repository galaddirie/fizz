defmodule Fizz.Collaboration.EditSession.Presence do
  @moduledoc """
  Tracks user presence in edit sessions using Phoenix.Presence.

  Manages:
  - Who is currently in the session
  - Cursor positions
  - Step selections
  - Step focus (config panel open)

  ## Important Implementation Notes

  Phoenix.Presence broadcasts `presence_diff` events automatically when:
  - A process is tracked via `track/4`
  - A process updates its metadata via `update/4`
  - A tracked process terminates

  Subscribers to the presence topic will receive:
  ```
  %Phoenix.Socket.Broadcast{
    topic: "edit_presence:workflow_id",
    event: "presence_diff",
    payload: %{joins: %{...}, leaves: %{...}}
  }
  ```
  """
  use Phoenix.Presence,
    otp_app: :fizz,
    pubsub_server: Fizz.PubSub

  require Logger

  @type cursor :: %{x: number(), y: number()}

  @type presence_meta :: %{
          user: %{id: String.t(), email: String.t(), name: String.t() | nil},
          cursor: cursor() | nil,
          dragging_steps: %{optional(String.t()) => %{x: number(), y: number()}} | nil,
          dragging_groups:
            %{
              optional(String.t()) => %{
                x: number(),
                y: number(),
                width: number(),
                height: number()
              }
            }
            | nil,
          selected_steps: [String.t()],
          focused_step: String.t() | nil,
          joined_at: DateTime.t()
        }

  @doc "Topic for a workflow's edit session presence."
  def topic(workflow_id), do: "edit_presence:#{workflow_id}"

  @doc """
  Track a user joining an edit session.

  This will broadcast a presence_diff to all subscribers with the new user
  in the `joins` payload.
  """
  def track_user(workflow_id, user, %Phoenix.LiveView.Socket{}) do
    do_track(workflow_id, user, self())
  end

  def track_user(workflow_id, user, %Phoenix.Socket{} = socket) do
    do_track_with_socket(workflow_id, user, socket)
  end

  def track_user(workflow_id, user, pid) when is_pid(pid) do
    do_track(workflow_id, user, pid)
  end

  defp do_track(workflow_id, user, pid) do
    meta = build_meta(user)
    topic = topic(workflow_id)

    Logger.debug("Tracking user #{user.id} on topic #{topic} with pid #{inspect(pid)}")

    case track(pid, topic, user.id, meta) do
      {:ok, _ref} = result ->
        Logger.debug("Successfully tracked user #{user.id}")
        result

      {:error, reason} = error ->
        Logger.error("Failed to track user #{user.id}: #{inspect(reason)}")
        error
    end
  end

  defp do_track_with_socket(workflow_id, user, socket) do
    meta = build_meta(user)
    topic = topic(workflow_id)

    case track(socket, topic, user.id, meta) do
      {:ok, _ref} = result ->
        result

      {:error, reason} = error ->
        Logger.error("Failed to track user #{user.id}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Update user's cursor position.

  This broadcasts a presence_diff with the updated metadata.
  """
  def update_cursor(workflow_id, user_id, %{x: _, y: _} = position) do
    update_interaction(workflow_id, user_id, position, nil, nil)
  end

  def update_cursor(_workflow_id, _user_id, nil), do: :ok

  @doc """
  Update user's interaction state (cursor and dragging nodes).
  """
  def update_interaction(workflow_id, user_id, cursor, dragging_steps, dragging_groups \\ nil) do
    topic = topic(workflow_id)

    case update(self(), topic, user_id, fn meta ->
           meta =
             if is_map(cursor) do
               Map.put(meta, :cursor, cursor)
             else
               meta
             end

           meta
           |> Map.put(:dragging_steps, dragging_steps)
           |> Map.put(:dragging_groups, dragging_groups)
         end) do
      {:ok, _ref} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to update interaction for user #{user_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Update user's step selection.

  This broadcasts a presence_diff with the updated selection.
  """
  def update_selection(workflow_id, user_id, step_ids) when is_list(step_ids) do
    topic = topic(workflow_id)

    case update(self(), topic, user_id, fn meta ->
           Map.put(meta, :selected_steps, step_ids)
         end) do
      {:ok, _ref} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to update selection for user #{user_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Update user's focused step (config panel open).

  This broadcasts a presence_diff with the updated focus.
  """
  def update_focus(workflow_id, user_id, step_id) do
    topic = topic(workflow_id)

    case update(self(), topic, user_id, fn meta ->
           Map.put(meta, :focused_step, step_id)
         end) do
      {:ok, _ref} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to update focus for user #{user_id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc "Clear user's focus."
  def clear_focus(workflow_id, user_id) do
    update_focus(workflow_id, user_id, nil)
  end

  @doc """
  Untrack a user from the session.

  This broadcasts a presence_diff with the user in the `leaves` payload.
  Note: This happens automatically when the tracked process dies.
  """
  def untrack_user(workflow_id, user_id) do
    untrack(self(), topic(workflow_id), user_id)
  end

  @doc "Get all users in a session as a map of user_id => presence data."
  def list_users(workflow_id) do
    list(topic(workflow_id))
  end

  @doc "Count users in a session."
  def count(workflow_id) do
    workflow_id
    |> topic()
    |> list()
    |> map_size()
  end

  @doc "Get a specific user's presence."
  def get_user(workflow_id, user_id) do
    workflow_id
    |> list_users()
    |> Map.get(user_id)
  end

  @doc """
  Check if a user is present in a session.
  """
  def user_present?(workflow_id, user_id) do
    workflow_id
    |> list_users()
    |> Map.has_key?(user_id)
  end

  # =============================================================================
  # Private Helpers
  # =============================================================================

  defp build_meta(user) do
    name = Map.get(user, :name) || Map.get(user, "name") || user.email

    %{
      user: %{
        id: user.id,
        email: user.email,
        name: name
      },
      cursor: nil,
      dragging_steps: nil,
      dragging_groups: nil,
      selected_steps: [],
      focused_step: nil,
      joined_at: DateTime.utc_now()
    }
  end
end
