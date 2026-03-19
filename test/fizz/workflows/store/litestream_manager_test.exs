defmodule Fizz.Workflows.Store.LitestreamManagerTest do
  use ExUnit.Case, async: true

  alias Fizz.Workflows.Store.LitestreamManager
  alias Fizz.Workflows.Store.Sqlite

  setup do
    tmp_dir =
      Path.join(
        System.tmp_dir!(),
        "fizz-litestream-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp_dir)
    on_exit(fn -> File.rm_rf(tmp_dir) end)

    %{tmp_dir: tmp_dir}
  end

  test "config generation produces directory-mode replication YAML", %{tmp_dir: tmp_dir} do
    assert {:ok, config_path} =
             LitestreamManager.generate_config(
               data_dir: tmp_dir,
               s3_bucket: "bucket",
               s3_prefix: "workflows",
               aws_region: "us-east-1"
             )

    content = File.read!(config_path)

    assert content =~ "dir: '#{Path.expand(tmp_dir)}'"
    assert content =~ "pattern: \"*.sqlite\""
    assert content =~ "recursive: true"
    assert content =~ "watch: true"
    assert content =~ "bucket: 'bucket'"
    assert content =~ "path: 'workflows'"
  end

  test "config generation includes endpoint for s3-compatible services", %{tmp_dir: tmp_dir} do
    assert {:ok, config_path} =
             LitestreamManager.generate_config(
               data_dir: tmp_dir,
               s3_bucket: "bucket",
               s3_prefix: "workflows",
               aws_region: "us-east-1",
               s3_endpoint: "http://127.0.0.1:9000"
             )

    content = File.read!(config_path)

    assert content =~ "endpoint: 'http://127.0.0.1:9000'"
  end

  test "restore computes the correct S3 replica URL from run_id", %{tmp_dir: tmp_dir} do
    source_db = Path.join(tmp_dir, "source.sqlite")
    restore_log = Path.join(tmp_dir, "restore.log")
    fake_bin = Path.join(tmp_dir, "fake-litestream")
    run_id = Ecto.UUID.generate()

    create_valid_sqlite(source_db)
    write_fake_litestream(fake_bin, source_db, restore_log)

    assert {:ok, local_path} =
             LitestreamManager.restore(
               run_id,
               data_dir: tmp_dir,
               org_id: "org_123",
               project_id: "project_456",
               s3_bucket: "bucket",
               s3_prefix: "workflows",
               bin_path: fake_bin
             )

    expected_url =
      LitestreamManager.replica_url(
        run_id,
        org_id: "org_123",
        project_id: "project_456",
        s3_bucket: "bucket",
        s3_prefix: "workflows"
      )

    assert File.exists?(local_path)
    assert File.read!(restore_log) =~ expected_url
  end

  test "replica_url includes endpoint query parameter when configured" do
    run_id = Ecto.UUID.generate()

    url =
      LitestreamManager.replica_url(
        run_id,
        org_id: "org_123",
        project_id: "project_456",
        s3_bucket: "bucket",
        s3_prefix: "workflows",
        s3_endpoint: "http://127.0.0.1:9000"
      )

    assert url =~ "s3://bucket/workflows/"
    assert url =~ "endpoint=http%3A%2F%2F127.0.0.1%3A9000"
  end

  test "restore refuses to overwrite an existing local file", %{tmp_dir: tmp_dir} do
    run_id = Ecto.UUID.generate()

    local_path =
      LitestreamManager.local_path(
        run_id,
        data_dir: tmp_dir,
        org_id: "org_123",
        project_id: "project_456"
      )

    File.mkdir_p!(Path.dirname(local_path))
    File.write!(local_path, "already here")

    assert {:error, :already_exists} =
             LitestreamManager.restore(
               run_id,
               data_dir: tmp_dir,
               org_id: "org_123",
               project_id: "project_456",
               s3_bucket: "bucket",
               s3_prefix: "workflows",
               bin_path: Path.join(tmp_dir, "missing-litestream")
             )
  end

  test "manager reports down when the binary is unavailable", %{tmp_dir: tmp_dir} do
    name = unique_name()

    start_supervised!(
      {LitestreamManager,
       name: name,
       data_dir: tmp_dir,
       s3_bucket: "bucket",
       s3_prefix: "workflows",
       aws_region: "us-east-1",
       bin_path: Path.join(tmp_dir, "missing-litestream")}
    )

    assert :down = LitestreamManager.status(server: name)
  end

  test "manager reports running when the port is alive", %{tmp_dir: tmp_dir} do
    fake_bin = Path.join(tmp_dir, "fake-litestream")

    write_fake_litestream(
      fake_bin,
      Path.join(tmp_dir, "source.sqlite"),
      Path.join(tmp_dir, "restore.log")
    )

    name = unique_name()

    start_supervised!(
      {LitestreamManager,
       name: name,
       data_dir: tmp_dir,
       s3_bucket: "bucket",
       s3_prefix: "workflows",
       aws_region: "us-east-1",
       bin_path: fake_bin}
    )

    assert :running = LitestreamManager.status(server: name)
  end

  defp create_valid_sqlite(path) do
    assert :ok =
             Sqlite.with_db(path, [create_dirs?: true], fn db ->
               Sqlite.execute(db, "CREATE TABLE IF NOT EXISTS test (id INTEGER PRIMARY KEY)")
             end)
  end

  defp write_fake_litestream(path, source_db, restore_log) do
    script = """
    #!/bin/sh
    if [ "$1" = "replicate" ]; then
      while true; do
        sleep 1
      done
    fi

    if [ "$1" = "restore" ]; then
      echo "$@" > "#{restore_log}"
      cp "#{source_db}" "$3"
      exit 0
    fi

    exit 1
    """

    File.write!(path, script)
    File.chmod!(path, 0o755)
  end

  defp unique_name do
    Module.concat([__MODULE__, "Manager#{System.unique_integer([:positive])}"])
  end
end
