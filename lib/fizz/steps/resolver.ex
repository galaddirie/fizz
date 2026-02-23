defmodule Fizz.Steps.Resolver do
  @moduledoc """
  Behaviour for field resolvers that provide dynamic options in step config UIs.

  Step executors reference a resolver module directly in their `@config_schema`
  under the `"ui" => "resolver"` key. The system calls `resolve/1` on that module
  to fetch options for the field.

  ## Implementing a Resolver

      defmodule MyApp.MyResolver do
        @behaviour Fizz.Steps.Resolver

        @impl true
        def resolve(%{q: q, params: params, context: context}) do
          # Return {:ok, options} or {:error, reason}
          {:ok, [%{"id" => "1", "label" => "Option 1"}]}
        end
      end

  Then reference it in the config schema:

      "ui" => %{
        "component" => "select",
        "resolver" => MyApp.MyResolver,
        "params" => %{}
      }
  """

  @type args :: %{
          q: String.t(),
          params: map(),
          context: map()
        }

  @callback resolve(args()) :: {:ok, [map()]} | {:error, term()}
end
