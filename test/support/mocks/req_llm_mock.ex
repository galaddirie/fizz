defmodule Fizz.TestSupport.ReqLLMMock do
  @moduledoc false

  def generate_text(model, messages, opts) do
    send(self(), {:req_llm_called, :generate_text, model, messages, opts})
    {:ok, %{operation: :generate_text}}
  end

  def stream_text(model, messages, opts) do
    send(self(), {:req_llm_called, :stream_text, model, messages, opts})
    {:ok, %{operation: :stream_text}}
  end

  def generate_object(model, messages, object_schema, opts) do
    send(
      self(),
      {:req_llm_called, :generate_object, model, messages, object_schema, opts}
    )

    {:ok, %{operation: :generate_object}}
  end

  def generate_image(model, prompt_or_messages, opts) do
    send(self(), {:req_llm_called, :generate_image, model, prompt_or_messages, opts})
    {:ok, %{operation: :generate_image}}
  end
end
