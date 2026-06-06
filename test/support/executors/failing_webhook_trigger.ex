defmodule Fizz.TestSupport.Executors.FailingWebhookTrigger do
  use Fizz.Integrations.Steps.Definition,
    id: "failing_webhook_trigger",
    name: "Failing Webhook Trigger",
    category: "Test",
    description: "Webhook trigger used by tests to force normalize errors",
    icon: "hero-bolt",
    kind: :trigger

  @behaviour Fizz.Workflows.StepExecutor

  alias Fizz.Triggers.RegistrationSpec

  @impl true
  def registration_spec(_config, _context) do
    {:ok,
     %RegistrationSpec{
       kind: :webhook,
       params: %{
         "signature_header" => "x-hub-signature-256",
         "signature_algorithm" => "hmac-sha256"
       }
     }}
  end

  @impl true
  def match?(_config, _incoming_event), do: true

  @impl true
  def normalize_event(_config, _raw_event), do: {:error, :invalid_payload}

  @impl true
  def execute(_config, input, _ctx), do: {:ok, input}
end
