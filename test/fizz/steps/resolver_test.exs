defmodule Fizz.Steps.ResolverTest do
  use ExUnit.Case, async: true

  alias Fizz.Steps.Resolver

  defmodule FakeResolver do
    @behaviour Resolver

    @impl true
    def resolve(%{q: q, params: _params, context: _context}) do
      {:ok, [%{"id" => "1", "label" => "Result for: #{q}"}]}
    end
  end

  defmodule FailingResolver do
    @behaviour Resolver

    @impl true
    def resolve(_args) do
      {:error, :something_went_wrong}
    end
  end

  describe "behaviour contract" do
    test "a resolver returns {:ok, options}" do
      args = %{q: "test", params: %{}, context: %{}}
      assert {:ok, [%{"id" => "1", "label" => "Result for: test"}]} = FakeResolver.resolve(args)
    end

    test "a resolver can return {:error, reason}" do
      args = %{q: "", params: %{}, context: %{}}
      assert {:error, :something_went_wrong} = FailingResolver.resolve(args)
    end
  end

  describe "schema-based resolver lookup" do
    test "resolver module is stored as an atom in config schema" do
      # Verify the executor schemas reference modules, not strings
      {:ok, openai_type} = Fizz.Steps.Registry.get("openai_model")

      resolver =
        get_in(openai_type.config_schema, ["properties", "credential_ref", "ui", "resolver"])

      assert is_atom(resolver)
      assert resolver == Fizz.Integrations.CredentialsResolver
    end

    test "resolver module implements the behaviour" do
      {:ok, openai_type} = Fizz.Steps.Registry.get("openai_model")

      resolver =
        get_in(openai_type.config_schema, ["properties", "credential_ref", "ui", "resolver"])

      Code.ensure_loaded!(resolver)
      assert function_exported?(resolver, :resolve, 1)
    end
  end
end
