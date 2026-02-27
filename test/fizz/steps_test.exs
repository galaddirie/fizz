defmodule Fizz.StepsTest do
  use ExUnit.Case, async: true

  alias Fizz.Steps

  describe "default_step_name/1" do
    test "strips brand for em dash separated names" do
      assert Steps.default_step_name("Google Sheets — New Row") == "New Row"
    end

    test "strips brand for double-hyphen separated names" do
      assert Steps.default_step_name("Slack -- Send Message") == "Send Message"
    end

    test "keeps names without a brand separator unchanged" do
      assert Steps.default_step_name("HTTP Request") == "HTTP Request"
    end
  end
end
