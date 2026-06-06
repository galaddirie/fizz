defmodule Fizz.Workflows.Store.LitestreamManager do
  @moduledoc false

  use GenServer

  require Logger

  alias Fizz.Workflows.Store.Paths
  alias Fizz.Workflows.Store.Sqlite

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec generate_config(keyword()) :: {:ok, String.t()} | {:error, term()}
  def generate_config(opts) do
    data_dir =
      opts
      |> Keyword.fetch!(:data_dir)
      |> Path.expand()

    File.mkdir_p!(data_dir)

    config_path = Path.join(data_dir, "litestream.yml")

    config =
      [
        "dbs:\n",
        "  - dir: #{yaml_string(data_dir)}\n",
        "    pattern: \"*.sqlite\"\n",
        "    recursive: true\n",
        "    watch: true\n",
        "    replica:\n",
        "      type: s3\n",
        "      bucket: #{yaml_string(Keyword.fetch!(opts, :s3_bucket))}\n",
        "      path: #{yaml_string(Keyword.get(opts, :s3_prefix, "workflows"))}\n",
        "      region: #{yaml_string(Keyword.get(opts, :aws_region, "us-east-1"))}\n",
        endpoint_lines(opts),
        skip_verify_lines(opts),
        "      access-key-id: ${LITESTREAM_ACCESS_KEY_ID}\n",
        "      secret-access-key: ${LITESTREAM_SECRET_ACCESS_KEY}\n",
        "      sync-interval: 1s\n"
      ]
      |> IO.iodata_to_binary()

    case File.write(config_path, config) do
      :ok -> {:ok, config_path}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec restore(String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def restore(run_id, opts) do
    local_path = local_path(run_id, opts)

    cond do
      File.exists?(local_path) ->
        {:error, :already_exists}

      true ->
        local_path |> Path.dirname() |> File.mkdir_p!()

        replica_url = replica_url(run_id, opts)
        bin_path = binary_path(opts)

        with {:ok, _bin_path} <- validate_binary(bin_path) do
          case System.cmd(bin_path, ["restore", "-o", local_path, replica_url],
                 stderr_to_stdout: true
               ) do
            {_output, 0} ->
              case integrity_check(local_path) do
                :ok -> {:ok, local_path}
                {:error, reason} -> {:error, reason}
              end

            {output, exit_code} ->
              {:error, {:restore_failed, exit_code, output}}
          end
        end
    end
  end

  @spec status(keyword()) :: :running | :down
  def status(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)

    case Process.whereis(server) do
      nil ->
        :down

      _pid ->
        try do
          GenServer.call(server, :status)
        catch
          :exit, _reason -> :down
        end
    end
  end

  @spec wal_checkpoint(String.t()) :: :ok | {:error, term()}
  def wal_checkpoint(db_path) do
    Sqlite.with_db(db_path, [configure?: false], fn db ->
      Sqlite.wal_checkpoint(db, :truncate)
    end)
  end

  @spec replica_url(String.t(), keyword()) :: String.t()
  def replica_url(run_id, opts) do
    opts = normalize_path_opts(opts)
    base_url = Paths.replica_url(run_id, opts)

    case replica_query(opts) do
      "" -> base_url
      query -> "#{base_url}?#{query}"
    end
  end

  @spec local_path(String.t(), keyword()) :: String.t()
  def local_path(run_id, opts) do
    opts = normalize_path_opts(opts)

    Paths.db_path(
      Path.expand(Keyword.fetch!(opts, :data_dir)),
      run_id,
      opts[:org_id],
      opts[:project_id]
    )
  end

  @impl GenServer
  def init(opts) do
    state = %{
      status: :down,
      port: nil,
      data_dir: opts[:data_dir] |> Kernel.||("priv/workflow_data") |> Path.expand(),
      s3_bucket: Keyword.get(opts, :s3_bucket),
      s3_prefix: Keyword.get(opts, :s3_prefix, "workflows"),
      aws_region: Keyword.get(opts, :aws_region, "us-east-1"),
      s3_endpoint: Keyword.get(opts, :s3_endpoint),
      s3_skip_verify: Keyword.get(opts, :s3_skip_verify, false),
      bin_path: binary_path(opts),
      log_level: Keyword.get(opts, :log_level, "warn"),
      config_path: nil
    }

    {:ok, maybe_start_port(state)}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status =
      case state do
        %{status: :running, port: port} when is_port(port) ->
          if Port.info(port), do: :running, else: :down

        _ ->
          :down
      end

    {:reply, status, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    Logger.debug("litestream: #{String.trim(data)}")
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.error("litestream exited with status #{code}")
    {:stop, {:litestream_exit, code}, %{state | status: :down, port: nil}}
  end

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    if Port.info(port) do
      Port.close(port)
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp maybe_start_port(%{s3_bucket: nil} = state), do: state

  defp maybe_start_port(state) do
    with {:ok, _bin_path} <- validate_binary(state.bin_path),
         {:ok, config_path} <-
           generate_config(
             data_dir: state.data_dir,
             s3_bucket: state.s3_bucket,
             s3_prefix: state.s3_prefix,
             aws_region: state.aws_region,
             s3_endpoint: state.s3_endpoint,
             s3_skip_verify: state.s3_skip_verify
           ),
         {:ok, port} <- open_port(state.bin_path, config_path, state.log_level) do
      %{state | status: :running, port: port, config_path: config_path}
    else
      {:error, :missing_binary} ->
        Logger.error(
          "litestream binary not found at #{state.bin_path}. Install it with `brew install litestream` locally or include it in the production image."
        )

        state

      {:error, reason} ->
        Logger.error("failed to start litestream: #{inspect(reason)}")
        state
    end
  end

  defp validate_binary(bin_path) do
    if File.exists?(bin_path) do
      {:ok, bin_path}
    else
      {:error, :missing_binary}
    end
  end

  defp open_port(bin_path, config_path, log_level) do
    port =
      Port.open({:spawn_executable, bin_path}, [
        :binary,
        :exit_status,
        :use_stdio,
        :stderr_to_stdout,
        :hide,
        args: ["replicate", "-config", config_path, "-log-level", log_level]
      ])

    {:ok, port}
  rescue
    exception ->
      {:error, exception}
  end

  defp integrity_check(local_path) do
    case Sqlite.with_db(local_path, [configure?: false], fn db ->
           Sqlite.first_value(db, "PRAGMA integrity_check")
         end) do
      {:ok, "ok"} -> :ok
      {:ok, result} -> {:error, {:integrity_check_failed, result}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp binary_path(opts) do
    Keyword.get_lazy(opts, :bin_path, fn ->
      System.find_executable("litestream") || "litestream"
    end)
  end

  defp normalize_path_opts(opts) do
    org_id = Keyword.get(opts, :org_id, Keyword.get(opts, :workos_organization_id))

    Keyword.put(opts, :org_id, org_id)
  end

  defp endpoint_lines(opts) do
    case Keyword.get(opts, :s3_endpoint) do
      endpoint when is_binary(endpoint) and byte_size(endpoint) > 0 ->
        ["      endpoint: ", yaml_string(endpoint), "\n"]

      _ ->
        []
    end
  end

  defp skip_verify_lines(opts) do
    case Keyword.get(opts, :s3_skip_verify, false) do
      true -> "      skip-verify: true\n"
      _ -> []
    end
  end

  defp replica_query(opts) do
    %{}
    |> maybe_put_query_param("endpoint", Keyword.get(opts, :s3_endpoint))
    |> maybe_put_query_param("skip-verify", Keyword.get(opts, :s3_skip_verify))
    |> URI.encode_query()
  end

  defp maybe_put_query_param(params, _key, nil), do: params
  defp maybe_put_query_param(params, _key, false), do: params
  defp maybe_put_query_param(params, key, true), do: Map.put(params, key, "true")

  defp maybe_put_query_param(params, key, value) when is_binary(value) and byte_size(value) > 0,
    do: Map.put(params, key, value)

  defp maybe_put_query_param(params, _key, _value), do: params

  defp yaml_string(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("'", "''")

    "'#{escaped}'"
  end
end
