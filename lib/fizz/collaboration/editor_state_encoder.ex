defimpl LiveVue.Encoder, for: Fizz.Collaboration.EditorState do
  def encode(state, opts) do
    data = %{
      workflow_id: state.workflow_id,
      pinned_outputs: state.pinned_outputs,
      disabled_steps: MapSet.to_list(state.disabled_steps),
      step_locks: state.step_locks,
      webhook_test: state.webhook_test
    }

    LiveVue.Encoder.encode(data, opts)
  end
end
