defmodule Fizz.Integrations.AI.ModelCatalogTest do
  use ExUnit.Case, async: true

  alias Fizz.Integrations.AI.ModelCatalog
  alias Fizz.Integrations.Library.Anthropic.ModelResolver, as: AnthropicModelResolver
  alias Fizz.Integrations.Library.OpenAI.ModelResolver, as: OpenAIModelResolver

  describe "chat_model_options/2" do
    test "lists current OpenAI text chat models from the packaged catalog" do
      options = ModelCatalog.chat_model_options(:openai)
      values = Enum.map(options, & &1["value"])

      assert "gpt-5.5" in values
      assert "gpt-5.4-mini" in values
      refute "text-embedding-3-large" in values
      refute "gpt-image-1" in values
      assert Enum.all?(values, &(not String.starts_with?(&1, "openai:")))
    end

    test "filters model options by id or display name" do
      options = ModelCatalog.chat_model_options(:openai, "5.5")
      values = Enum.map(options, & &1["value"])

      assert "gpt-5.5" in values

      assert Enum.all?(options, fn option ->
               haystack =
                 [option["label"], option["value"], option["description"]]
                 |> Enum.reject(&is_nil/1)
                 |> Enum.join(" ")
                 |> String.downcase()

               String.contains?(haystack, "5.5")
             end)
    end

    test "lists Anthropic text chat models from the packaged catalog" do
      options = ModelCatalog.chat_model_options(:anthropic)
      values = Enum.map(options, & &1["value"])

      assert "claude-sonnet-4-6" in values
      assert Enum.all?(values, &(not String.starts_with?(&1, "anthropic:")))
    end
  end

  describe "provider resolvers" do
    test "OpenAI resolver returns searchable options" do
      assert {:ok, options} = OpenAIModelResolver.resolve(%{q: "5.5"})

      assert Enum.any?(options, &(&1["value"] == "gpt-5.5"))
    end

    test "Anthropic resolver returns searchable options" do
      assert {:ok, options} = AnthropicModelResolver.resolve(%{q: "sonnet"})

      assert Enum.any?(options, &(&1["value"] == "claude-sonnet-4-6"))
    end
  end
end
