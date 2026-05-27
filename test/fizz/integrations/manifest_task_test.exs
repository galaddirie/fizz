defmodule Fizz.Integrations.ManifestTaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "mix task generates a manifest module file" do
    output_path =
      Path.join(
        System.tmp_dir!(),
        "fizz-integration-manifest-#{System.unique_integer([:positive])}.ex"
      )

    on_exit(fn -> File.rm(output_path) end)

    assert capture_io(fn ->
             Mix.Tasks.Fizz.Gen.IntegrationManifest.run(["--output", output_path])
           end) =~ "Generated"

    assert {:ok, content} = File.read(output_path)
    assert content =~ "defmodule Fizz.Integrations.Manifest"
    assert content =~ "Fizz.Integrations.Providers.GoogleOAuth"
    assert content =~ "Fizz.Integrations.Google.Sheets.Actions.AppendRow"
  end

  test "mix task check mode verifies the generated manifest is current" do
    assert capture_io(fn ->
             Mix.Tasks.Fizz.Gen.IntegrationManifest.run(["--check"])
           end) =~ "is up to date"
  end
end
