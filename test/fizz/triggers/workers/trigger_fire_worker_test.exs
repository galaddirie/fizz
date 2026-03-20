defmodule Fizz.Triggers.Workers.TriggerFireWorkerTest do
  use Fizz.DataCase, async: false
  use Oban.Testing, repo: Fizz.Repo

  import Ecto.Query
  import Fizz.WorkflowsFixtures

  alias Fizz.Repo
  alias Fizz.Triggers.TriggerEvent
  alias Fizz.Triggers.TriggerRegistration
  alias Fizz.Triggers.Workers.TriggerFireWorker
  alias Fizz.Workflows
  alias Fizz.Workflows.Runner.Worker
  alias Fizz.Workflows.SignalInbox
  alias Fizz.Workflows.WorkflowRun

  test "definition-level registration creates a workflow run with triggered_by metadata" do
    scope = project_scope_fixture()
    %{version: version} = published_version_fixture(scope, manual_trigger_snapshot_attrs())

    registration =
      Repo.one!(from(reg in TriggerRegistration, where: reg.definition_version_id == ^version.id))

    assert :ok =
             perform_job(TriggerFireWorker, %{
               trigger_registration_id: registration.id,
               event_id: "evt-definition",
               normalized_data: %{"payload" => "hello"}
             })

    created_run =
      eventually(fn ->
        WorkflowRun
        |> where([run], run.workflow_definition_version_id == ^version.id)
        |> order_by([run], desc: run.inserted_at)
        |> limit(1)
        |> Repo.one()
        |> case do
          %WorkflowRun{triggered_by: triggered_by} = run when is_map(triggered_by) ->
            {:ok, run}

          _ ->
            :retry
        end
      end)

    assert created_run.input == %{"payload" => "hello"}
    assert created_run.triggered_by["trigger_registration_id"] == registration.id
    assert created_run.triggered_by["trigger_step_id"] == registration.step_id
    assert created_run.triggered_by["trigger_kind"] == registration.kind
    assert created_run.triggered_by["event_id"] == "evt-definition"

    assert %TriggerEvent{status: "fired", run_id: run_id} =
             Repo.one!(
               from(event in TriggerEvent,
                 where:
                   event.trigger_registration_id == ^registration.id and
                     event.event_id == ^"evt-definition"
               )
             )

    assert run_id == created_run.id

    completed_run =
      eventually(fn ->
        case Workflows.get_run(scope, created_run.id) do
          {:ok, %WorkflowRun{status: :completed} = workflow_run} -> {:ok, workflow_run}
          _ -> :retry
        end
      end)

    assert completed_run.status == :completed
    assert_worker_shutdown(created_run.id)
  end

  test "run-level registration delivers a signal to the existing run" do
    scope = project_scope_fixture()
    %{version: version} = published_version_fixture(scope, long_running_snapshot_attrs(100))

    assert {:ok, run} = Workflows.start_run(scope, version, %{"kind" => "initial"})

    _sleeping_run =
      eventually(fn ->
        case Workflows.get_run(scope, run.id) do
          {:ok, %WorkflowRun{status: status} = workflow_run}
          when status in [:sleeping, :running, :passivated] ->
            {:ok, workflow_run}

          _ ->
            :retry
        end
      end)

    registration =
      %TriggerRegistration{}
      |> TriggerRegistration.changeset(%{
        workflow_definition_id: version.workflow_definition_id,
        definition_version_id: version.id,
        step_id: "external-signal",
        project_id: scope.project.id,
        workos_organization_id: scope.project.workos_organization_id,
        run_id: run.id,
        kind: "manual",
        status: "active",
        registration_params: %{},
        config_digest: "run-level-digest"
      })
      |> Repo.insert!()

    assert :ok =
             perform_job(TriggerFireWorker, %{
               trigger_registration_id: registration.id,
               event_id: "evt-run",
               normalized_data: %{"payload" => "resume"}
             })

    delivered_signal =
      eventually(fn ->
        SignalInbox
        |> where([signal], signal.run_id == ^run.id and signal.signal_id == ^"evt-run")
        |> Repo.one()
        |> case do
          %SignalInbox{status: status} = signal when status in [:delivered, :pending] ->
            {:ok, signal}

          _ ->
            :retry
        end
      end)

    assert delivered_signal.signal_name == registration.step_id

    assert Repo.aggregate(
             from(workflow_run in WorkflowRun,
               where: workflow_run.workflow_definition_version_id == ^version.id
             ),
             :count,
             :id
           ) == 1

    assert %TriggerEvent{status: "fired", run_id: event_run_id} =
             Repo.one!(
               from(event in TriggerEvent,
                 where:
                   event.trigger_registration_id == ^registration.id and
                     event.event_id == ^"evt-run"
               )
             )

    assert event_run_id == run.id

    completed_run =
      eventually(fn ->
        case Workflows.get_run(scope, run.id) do
          {:ok, %WorkflowRun{status: :completed} = workflow_run} -> {:ok, workflow_run}
          _ -> :retry
        end
      end)

    assert completed_run.status == :completed
    assert_worker_shutdown(run.id)
  end

  test "schedule trigger self-chains by enqueuing next TriggerFireWorker after firing" do
    scope = project_scope_fixture()

    %{version: version} =
      published_version_fixture(scope, schedule_trigger_snapshot_attrs())

    registration =
      Repo.one!(
        from(reg in TriggerRegistration,
          where: reg.definition_version_id == ^version.id and reg.kind == "schedule"
        )
      )

    due_at = DateTime.add(DateTime.utc_now(), -1, :second)

    registration =
      registration
      |> TriggerRegistration.changeset(%{next_fire_at: due_at})
      |> Repo.update!()

    event_id = "sched_#{registration.id}_#{DateTime.to_unix(due_at)}"

    assert :ok =
             perform_job(TriggerFireWorker, %{
               trigger_registration_id: registration.id,
               event_id: event_id,
               normalized_data: %{"scheduled_at" => DateTime.to_iso8601(due_at)}
             })

    # Verify self-chaining: a new job should be enqueued with a future scheduled_at
    next_jobs =
      all_enqueued(worker: TriggerFireWorker)
      |> Enum.filter(fn job ->
        job.args["trigger_registration_id"] == registration.id and
          job.args["event_id"] != event_id
      end)

    assert length(next_jobs) >= 1
    [next_job] = next_jobs
    assert next_job.scheduled_at != nil

    # The registration's next_fire_at should be updated
    updated_registration = Repo.get!(TriggerRegistration, registration.id)
    assert DateTime.compare(updated_registration.next_fire_at, due_at) == :gt
  end

  defp schedule_trigger_snapshot_attrs do
    trigger =
      step(%{
        id: Ecto.UUID.generate(),
        type_id: "schedule_trigger",
        name: "Schedule Trigger",
        config: %{"interval_seconds" => 60}
      })

    debug = step(%{id: Ecto.UUID.generate(), type_id: "debug", name: "Debug"})

    snapshot_attrs(%{
      steps: [trigger, debug],
      connections: [connection(%{source_step_id: trigger.id, target_step_id: debug.id})]
    })
  end

  defp manual_trigger_snapshot_attrs do
    snapshot_attrs(%{
      steps: [step(%{id: Ecto.UUID.generate(), type_id: "manual_input", name: "Manual"})]
    })
  end

  defp eventually(fun, attempts \\ 50)

  defp eventually(fun, attempts) when attempts > 0 do
    case fun.() do
      {:ok, value} ->
        value

      :retry ->
        receive do
        after
          20 -> eventually(fun, attempts - 1)
        end
    end
  end

  defp eventually(_fun, 0), do: flunk("condition not met")

  defp assert_worker_shutdown(run_id) do
    eventually(fn ->
      case Worker.lookup(run_id) do
        nil -> {:ok, :stopped}
        _pid -> :retry
      end
    end)
  end
end
