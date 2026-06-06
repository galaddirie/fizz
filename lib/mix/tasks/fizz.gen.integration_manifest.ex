defmodule Mix.Tasks.Fizz.Gen.IntegrationManifest do
  @moduledoc """
  Generates the built-in integration manifest module.

      mix fizz.gen.integration_manifest
      mix fizz.gen.integration_manifest --output /tmp/manifest.ex
  """

  use Mix.Task

  @shortdoc "Generates Fizz.Integrations.Catalog.Manifest"
  @default_output "lib/fizz/integrations/catalog/manifest.ex"
  @source_output "lib/fizz/integrations/catalog/manifest.ex"

  @impl true
  def run(args) do
    Mix.Task.run("app.config")

    {opts, _argv, _invalid} =
      OptionParser.parse(args, strict: [check: :boolean, output: :string], aliases: [o: :output])

    output_path = Keyword.get(opts, :output, @default_output)
    content = render_manifest()

    if Keyword.get(opts, :check, false) do
      check_manifest!(output_path, content)
    else
      File.mkdir_p!(Path.dirname(output_path))
      File.write!(output_path, content)

      Mix.shell().info("Generated #{output_path}")
    end
  end

  defp render_manifest do
    File.read!(@source_output)
  end

  defp check_manifest!(output_path, content) do
    case File.read(output_path) do
      {:ok, ^content} ->
        Mix.shell().info("#{output_path} is up to date")

      {:ok, _stale_content} ->
        Mix.raise("#{output_path} is stale; run mix fizz.gen.integration_manifest")

      {:error, reason} ->
        Mix.raise("could not read #{output_path}: #{:file.format_error(reason)}")
    end
  end
end
