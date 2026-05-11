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

  describe "slot-backed credential fields" do
    test "credential fields use the slot component in config schema" do
      {:ok, openai_type} = Fizz.Steps.Registry.get("openai_model")

      ui = get_in(openai_type.config_schema, ["properties", "credential_ref", "ui"])

      assert ui["component"] == "slot"
      assert ui["slot_kind"] == "credential"
      assert ui["slot_key"] == "auth"
      assert ui["spec"] == %{"provider" => "openai_api_key", "auth_type" => "api_key"}
    end

    test "credential field default config is a slot declaration" do
      {:ok, openai_type} = Fizz.Steps.Registry.get("openai_model")

      default_config = Fizz.Steps.Registry.get_default_config(openai_type.id)

      assert %{
               "$slot" => true,
               "kind" => "credential",
               "slot_key" => "auth",
               "spec" => %{"provider" => "openai_api_key", "auth_type" => "api_key"}
             } = default_config["credential_ref"]
    end
  end
end
