defmodule FizzWeb.ExecutionLive.ShowPresenter do
  @moduledoc false

  alias Fizz.Accounts.User
  alias Fizz.Executions.Execution

  def execution_trigger_label(%Execution{} = execution) do
    execution
    |> trigger_type()
    |> humanize()
  end

  def trigger_payload(%Execution{trigger: %Execution.Trigger{data: data}}), do: data
  def trigger_payload(_), do: nil

  def trace_value(%Execution{metadata: %Execution.Metadata{trace_id: trace_id}}),
    do: trace_id || "-"

  def trace_value(_), do: "-"

  def correlation_value(%Execution{
        metadata: %Execution.Metadata{correlation_id: correlation_id}
      }),
      do: correlation_id || "-"

  def correlation_value(_), do: "-"

  def parent_execution_value(%Execution{
        metadata: %Execution.Metadata{parent_execution_id: parent_execution_id}
      }),
      do: parent_execution_id || "-"

  def parent_execution_value(_), do: "-"

  def triggered_by_label(%Execution{triggered_by_user: %User{email: email}}), do: email
  def triggered_by_label(%Execution{triggered_by_user_id: nil}), do: "System"
  def triggered_by_label(_), do: "Unknown"

  def execution_type_label(nil), do: "-"
  def execution_type_label(type), do: humanize(type)

  def execution_type_class(:production),
    do:
      "bg-emerald-500/10 text-emerald-700 ring-emerald-500/30 dark:bg-emerald-500/20 dark:text-emerald-300"

  def execution_type_class(:preview),
    do: "bg-sky-500/10 text-sky-700 ring-sky-500/30 dark:bg-sky-500/20 dark:text-sky-300"

  def execution_type_class(:partial),
    do:
      "bg-amber-500/10 text-amber-700 ring-amber-500/30 dark:bg-amber-500/20 dark:text-amber-300"

  def execution_type_class(_), do: "bg-base-200/60 text-base-content/70 ring-base-200"

  def status_pill_class(:completed),
    do:
      "bg-emerald-500/10 text-emerald-700 ring-emerald-500/30 dark:bg-emerald-500/20 dark:text-emerald-300"

  def status_pill_class(:failed),
    do: "bg-rose-500/10 text-rose-700 ring-rose-500/30 dark:bg-rose-500/20 dark:text-rose-300"

  def status_pill_class(:running),
    do: "bg-sky-500/10 text-sky-700 ring-sky-500/30 dark:bg-sky-500/20 dark:text-sky-300"

  def status_pill_class(:pending),
    do:
      "bg-amber-500/10 text-amber-700 ring-amber-500/30 dark:bg-amber-500/20 dark:text-amber-300"

  def status_pill_class(:paused),
    do:
      "bg-amber-500/10 text-amber-700 ring-amber-500/30 dark:bg-amber-500/20 dark:text-amber-300"

  def status_pill_class(:cancelled), do: "bg-base-200/60 text-base-content/70 ring-base-200"

  def status_pill_class(:timeout),
    do: "bg-rose-500/10 text-rose-700 ring-rose-500/30 dark:bg-rose-500/20 dark:text-rose-300"

  def status_pill_class(:queued),
    do:
      "bg-violet-500/10 text-violet-700 ring-violet-500/30 dark:bg-violet-500/20 dark:text-violet-300"

  def status_pill_class(:skipped), do: "bg-base-200/60 text-base-content/70 ring-base-200"
  def status_pill_class(_), do: "bg-base-200/60 text-base-content/70 ring-base-200"

  def humanize(nil), do: "-"

  def humanize(value) when is_atom(value) do
    value
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  def humanize(value), do: to_string(value)

  def sort_step_executions(step_executions) do
    Enum.sort_by(step_executions, fn step ->
      case step.inserted_at || step.started_at do
        nil -> 0
        datetime -> DateTime.to_unix(datetime, :microsecond)
      end
    end)
  end

  def fetch_payload_value(payload, key) when is_map(payload) do
    Map.get(payload, key) || Map.get(payload, Atom.to_string(key))
  end

  def fetch_payload_value(_payload, _key), do: nil

  def payload_preview(nil), do: "-"

  def payload_preview(payload) do
    payload
    |> inspect(limit: 6, printable_limit: 200, pretty: true)
    |> String.replace(~r/\s+/, " ")
    |> truncate(90)
  end

  def format_payload(nil), do: "-"

  def format_payload(payload) do
    case Jason.encode(payload, pretty: true) do
      {:ok, json} -> json
      {:error, _} -> inspect(payload, pretty: true, limit: :infinity)
    end
  end

  def build_item_stats(step_executions) do
    by_step_id =
      step_executions
      |> Enum.group_by(& &1.step_id)
      |> Enum.into(%{}, fn {step_id, executions} ->
        items_total =
          executions
          |> Enum.find_value(fn se -> se.items_total end) ||
            if(length(executions) > 1, do: length(executions), else: 1)

        completed = Enum.count(executions, &(&1.status == :completed))
        failed = Enum.count(executions, &(&1.status == :failed))
        running = Enum.count(executions, &(&1.status == :running))
        skipped = Enum.count(executions, &(&1.status == :skipped))

        {step_id,
         %{
           items_total: items_total,
           completed: completed,
           failed: failed,
           running: running,
           skipped: skipped,
           count: length(executions)
         }}
      end)

    summary = %{
      total_item_runs: length(step_executions),
      multi_item_steps: Enum.count(by_step_id, fn {_id, stats} -> stats.items_total > 1 end)
    }

    %{by_step_id: by_step_id, summary: summary}
  end

  def raw_execution_json(workflow, %Execution{} = execution, step_executions) do
    raw_payload = %{
      workflow: workflow_raw(workflow),
      execution: execution_raw(execution),
      trigger: execution.trigger,
      context: execution.context,
      output: execution.output,
      error: execution.error,
      metadata: execution.metadata,
      pinned: pinned_data(execution),
      step_executions: Enum.map(step_executions, &step_execution_raw/1)
    }

    format_payload(raw_payload)
  end

  defp trigger_type(%Execution{trigger: %Execution.Trigger{type: type}}), do: type
  defp trigger_type(_), do: nil

  defp truncate(value, max) when is_binary(value) and byte_size(value) > max do
    String.slice(value, 0, max) <> "..."
  end

  defp truncate(value, _max), do: value

  defp workflow_raw(nil), do: nil

  defp workflow_raw(workflow) do
    base_workflow =
      Map.take(workflow, [
        :id,
        :name,
        :description,
        :status,
        :public,
        :current_version_tag,
        :published_version_id,
        :user_id,
        :inserted_at,
        :updated_at
      ])

    definition =
      case workflow.published_version do
        %{} = published_version ->
          %{
            version_tag: published_version.version_tag,
            steps: published_version.steps,
            connections: published_version.connections,
            source_hash: published_version.source_hash,
            published_at: published_version.published_at,
            source: "published"
          }

        nil ->
          case workflow.draft do
            %{} = draft ->
              %{
                version_tag: nil,
                steps: draft.steps,
                connections: draft.connections,
                source_hash: nil,
                published_at: nil,
                source: "draft"
              }

            _ ->
              nil
          end
      end

    Map.put(base_workflow, :definition, definition)
  end

  defp execution_raw(%Execution{} = execution) do
    Map.take(execution, [
      :id,
      :workflow_id,
      :status,
      :execution_type,
      :trigger,
      :context,
      :output,
      :error,
      :waiting_for,
      :started_at,
      :completed_at,
      :expires_at,
      :metadata,
      :triggered_by_user_id,
      :inserted_at,
      :updated_at
    ])
  end

  defp step_execution_raw(step_execution) do
    Map.take(step_execution, [
      :id,
      :execution_id,
      :step_id,
      :step_type_id,
      :status,
      :input_data,
      :output_data,
      :output_item_count,
      :item_index,
      :items_total,
      :error,
      :attempt,
      :retry_of_id,
      :queued_at,
      :started_at,
      :completed_at,
      :metadata,
      :inserted_at,
      :updated_at
    ])
  end

  defp pinned_data(%Execution{} = execution) do
    extras = execution.metadata && execution.metadata.extras

    pinned_steps =
      case extras do
        %{} -> Map.get(extras, :pinned_steps) || Map.get(extras, "pinned_steps") || []
        _ -> []
      end

    pinned_outputs =
      if is_list(pinned_steps) and is_map(execution.context) do
        Map.take(execution.context, pinned_steps)
      else
        %{}
      end

    %{
      pinned_steps: pinned_steps,
      pinned_outputs: pinned_outputs,
      disabled_steps: fetch_metadata_list(extras, :disabled_steps)
    }
  end

  defp fetch_metadata_list(extras, key) when is_map(extras) do
    Map.get(extras, key) || Map.get(extras, Atom.to_string(key)) || []
  end

  defp fetch_metadata_list(_extras, _key), do: []
end
