defmodule Fizz.Triggers.SourcePoller do
  @moduledoc """
  Supervisable poller for one durable trigger source.
  """

  use GenServer

  alias Fizz.Triggers
  alias Fizz.Triggers.Dispatcher
  alias Fizz.Triggers.TriggerSource

  require Logger

  @default_lease_ttl_ms :timer.minutes(5)
  @min_schedule_ms 1_000

  def start_link(opts) do
    source_id = Keyword.fetch!(opts, :source_id)

    GenServer.start_link(__MODULE__, opts,
      name: {:via, Registry, {Fizz.Triggers.SourceRegistry, source_id}}
    )
  end

  @impl true
  def init(opts) do
    state = %{
      source_id: Keyword.fetch!(opts, :source_id),
      lease_owner: Keyword.get(opts, :lease_owner, default_lease_owner()),
      lease_ttl_ms: Keyword.get(opts, :lease_ttl_ms, @default_lease_ttl_ms)
    }

    {:ok, state, {:continue, :schedule}}
  end

  @impl true
  def handle_continue(:schedule, state) do
    schedule_next_poll(state.source_id)
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    case Triggers.get_source(state.source_id) do
      %TriggerSource{status: "active"} = source ->
        poll_source(source, state)
        schedule_next_poll(source.id)
        {:noreply, state}

      %TriggerSource{} ->
        {:stop, :normal, state}

      nil ->
        {:stop, :normal, state}
    end
  end

  def handle_info(message, state) do
    Logger.debug("trigger source poller ignoring message: #{inspect(message)}")
    {:noreply, state}
  end

  defp poll_source(%TriggerSource{} = source, state) do
    try do
      do_poll_source(source, state)
    rescue
      exception ->
        stacktrace = __STACKTRACE__
        record_poll_error(source, Exception.format(:error, exception, stacktrace))
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__
        record_poll_error(source, Exception.format(kind, reason, stacktrace))
    end
  end

  defp do_poll_source(%TriggerSource{} = source, state) do
    now = DateTime.utc_now()

    with :due <- due?(source, now),
         :ok <-
           Triggers.claim_source_for_poll(source.id, state.lease_owner, state.lease_ttl_ms, now),
         {:ok, module} <- source_module(source),
         context <- source_context(source),
         {:ok, result} <- module.poll(source.params, source.cursor, context) do
      result.events
      |> Enum.reduce_while(:ok, fn event, :ok ->
        event_id = module.event_id(event)

        case Dispatcher.dispatch_to_source_registrations(source.id, event, event_id) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
      |> case do
        :ok ->
          case commit_source(module, source.params, result, context) do
            :ok ->
              {:ok, _source} =
                Triggers.record_source_poll_success(source, result.cursor, DateTime.utc_now())

              :ok

            {:error, reason} ->
              {:ok, _source} = Triggers.record_source_poll_error(source, reason)
              :ok
          end

        {:error, reason} ->
          {:ok, _source} = Triggers.record_source_poll_error(source, reason)
          :ok
      end
    else
      :not_due ->
        :ok

      {:error, :busy} ->
        :ok

      {:backoff, reason} ->
        record_poll_error(source, reason)

      {:error, reason} ->
        record_poll_error(source, reason)
    end
  end

  defp record_poll_error(%TriggerSource{} = source, reason) do
    {:ok, _source} = Triggers.record_source_poll_error(source, reason)
    :ok
  end

  defp due?(%TriggerSource{backoff_until: %DateTime{} = backoff_until}, now) do
    if DateTime.compare(backoff_until, now) == :gt, do: :not_due, else: :due
  end

  defp due?(%TriggerSource{next_poll_at: %DateTime{} = next_poll_at}, now) do
    if DateTime.compare(next_poll_at, now) == :gt, do: :not_due, else: :due
  end

  defp due?(%TriggerSource{}, _now), do: :due

  defp schedule_next_poll(source_id) do
    source_id
    |> Triggers.get_source()
    |> next_poll_delay_ms()
    |> then(&Process.send_after(self(), :poll, &1))
  end

  defp next_poll_delay_ms(%TriggerSource{backoff_until: %DateTime{} = backoff_until}) do
    delay_until(backoff_until)
  end

  defp next_poll_delay_ms(%TriggerSource{lease_expires_at: %DateTime{} = lease_expires_at}) do
    delay_until(lease_expires_at)
  end

  defp next_poll_delay_ms(%TriggerSource{next_poll_at: %DateTime{} = next_poll_at}) do
    delay_until(next_poll_at)
  end

  defp next_poll_delay_ms(%TriggerSource{poll_interval_ms: interval}) when is_integer(interval) do
    min(interval, :timer.seconds(5))
  end

  defp next_poll_delay_ms(_source), do: :timer.seconds(5)

  defp delay_until(%DateTime{} = datetime) do
    diff_ms = DateTime.diff(datetime, DateTime.utc_now(), :millisecond)
    max(diff_ms, @min_schedule_ms)
  end

  defp source_module(%TriggerSource{source_module: source_module})
       when is_binary(source_module) do
    module =
      source_module
      |> normalized_module_name()
      |> String.to_existing_atom()

    case Code.ensure_loaded(module) do
      {:module, ^module} -> {:ok, module}
      _ -> {:error, {:source_module_not_loaded, source_module}}
    end
  rescue
    ArgumentError -> {:error, {:source_module_not_loaded, source_module}}
  end

  defp normalized_module_name("Elixir." <> _rest = source_module), do: source_module
  defp normalized_module_name(source_module), do: "Elixir." <> source_module

  defp source_context(%TriggerSource{} = source) do
    %{
      source_id: source.id,
      project_id: source.project_id,
      workos_organization_id: source.workos_organization_id,
      user_id: source.user_id
    }
  end

  defp commit_source(module, params, result, context) do
    if function_exported?(module, :commit, 3) do
      checkpoint = Map.get(result, :checkpoint) || Map.get(result, "checkpoint")
      module.commit(params, checkpoint, context)
    else
      :ok
    end
  end

  defp default_lease_owner do
    node_part = node() |> Atom.to_string()
    "source-poller:#{node_part}:#{System.unique_integer([:positive])}"
  end
end
