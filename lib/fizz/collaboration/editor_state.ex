defmodule Fizz.Collaboration.EditorState do
  @moduledoc """
  Editor state for a collaborative session.

  This state is persisted into the workflow draft's `editor_state` column so
  pins/disabled steps survive session restarts.
  """

  alias Fizz.Runtime.Serializer

  defstruct [
    :workflow_id,
    # %{step_id => output_data}
    pinned_outputs: %{},
    disabled_steps: MapSet.new(),
    disabled_mode: %{},
    # step_id for partial execution
    execution_start: nil,
    # %{step_id => user_id} - soft locks
    step_locks: %{},
    # %{step_id => DateTime} - for timeout
    lock_timestamps: %{},
    # %{path: string, method: string, step_id: string, enabled_by: string}
    webhook_test: nil
  ]

  # 30 seconds
  @lock_timeout_ms 30_000

  def pin_output(state, step_id, output_data) do
    %{state | pinned_outputs: Map.put(state.pinned_outputs, step_id, output_data)}
  end

  def unpin_output(state, step_id) do
    %{state | pinned_outputs: Map.delete(state.pinned_outputs, step_id)}
  end

  def disable_step(state, step_id, mode \\ :skip) do
    %{
      state
      | disabled_steps: MapSet.put(state.disabled_steps, step_id),
        disabled_mode: Map.put(state.disabled_mode, step_id, mode)
    }
  end

  def enable_step(state, step_id) do
    %{
      state
      | disabled_steps: MapSet.delete(state.disabled_steps, step_id),
        disabled_mode: Map.delete(state.disabled_mode, step_id)
    }
  end

  def enable_webhook_test(state, webhook_test) when is_map(webhook_test) do
    %{state | webhook_test: webhook_test}
  end

  def disable_webhook_test(state) do
    %{state | webhook_test: nil}
  end

  def to_storage(%__MODULE__{} = state) do
    %{
      "pinned_outputs" => normalize_pinned_outputs(state.pinned_outputs),
      "disabled_steps" => MapSet.to_list(state.disabled_steps),
      "disabled_mode" => state.disabled_mode
    }
  end

  @deprecated "Use to_storage/1"
  def to_settings(%__MODULE__{} = state), do: to_storage(state)

  def from_storage(workflow_id, editor_state, settings \\ %{})

  def from_storage(workflow_id, editor_state, settings)
      when is_map(editor_state) and is_map(settings) do
    source =
      if map_size(editor_state) > 0 do
        editor_state
      else
        resolve_editor_state(settings)
      end

    pinned_outputs =
      source
      |> Map.get("pinned_outputs") || Map.get(source, :pinned_outputs) ||
        %{}
        |> normalize_pinned_outputs()

    disabled_steps =
      source
      |> Map.get("disabled_steps") || Map.get(source, :disabled_steps) ||
        []
        |> List.wrap()

    disabled_mode =
      Map.get(source, "disabled_mode") || Map.get(source, :disabled_mode) || %{}

    %__MODULE__{
      workflow_id: workflow_id,
      pinned_outputs: pinned_outputs,
      disabled_steps: MapSet.new(disabled_steps),
      disabled_mode: disabled_mode
    }
  end

  def from_storage(workflow_id, _editor_state, _settings),
    do: %__MODULE__{workflow_id: workflow_id}

  def from_settings(workflow_id, settings) when is_map(settings) do
    from_storage(workflow_id, %{}, settings)
  end

  def from_settings(workflow_id, _settings),
    do: %__MODULE__{workflow_id: workflow_id}

  defp normalize_pinned_outputs(outputs) when is_map(outputs) do
    Map.new(outputs, fn {step_id, output} ->
      {to_string(step_id), Serializer.wrap_for_db(output)}
    end)
  end

  defp normalize_pinned_outputs(_outputs), do: %{}

  defp resolve_editor_state(settings) do
    case Map.get(settings, "editor_state") || Map.get(settings, :editor_state) do
      nil ->
        if has_editor_state_keys?(settings) do
          settings
        else
          %{}
        end

      editor_state ->
        editor_state
    end
  end

  defp has_editor_state_keys?(settings) do
    Enum.any?([:pinned_outputs, :disabled_steps, :disabled_mode], fn key ->
      Map.has_key?(settings, key) || Map.has_key?(settings, Atom.to_string(key))
    end)
  end

  def acquire_lock(state, step_id, user_id) do
    now = DateTime.utc_now()

    case Map.get(state.step_locks, step_id) do
      nil ->
        {:ok, put_lock(state, step_id, user_id, now)}

      ^user_id ->
        # Already locked by same user - refresh
        {:ok, put_lock(state, step_id, user_id, now)}

      other_user_id ->
        # Check if lock has expired
        lock_time = Map.get(state.lock_timestamps, step_id)

        if DateTime.diff(now, lock_time, :millisecond) > @lock_timeout_ms do
          {:ok, put_lock(state, step_id, user_id, now)}
        else
          {:locked, other_user_id}
        end
    end
  end

  def release_lock(state, step_id, user_id) do
    case Map.get(state.step_locks, step_id) do
      ^user_id ->
        release_lock(state, step_id)

      _ ->
        state
    end
  end

  def release_lock(state, step_id) do
    %{
      state
      | step_locks: Map.delete(state.step_locks, step_id),
        lock_timestamps: Map.delete(state.lock_timestamps, step_id)
    }
  end

  def put_lock(state, step_id, user_id, timestamp) do
    %{
      state
      | step_locks: Map.put(state.step_locks, step_id, user_id),
        lock_timestamps: Map.put(state.lock_timestamps, step_id, timestamp)
    }
  end
end
