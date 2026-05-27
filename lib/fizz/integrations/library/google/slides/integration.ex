defmodule Fizz.Integrations.Library.Google.Slides do
  @moduledoc """
  Google Slides product integration catalog entry.
  """

  use Fizz.Integrations.Contracts.StaticIntegration,
    id: "google_slides",
    display_name: "Google Slides",
    provider_id: "google_oauth",
    actions: ["google_slides_create_presentation", "google_slides_add_slide"],
    step_modules: [
      Fizz.Integrations.Library.Google.Slides.Actions.CreatePresentation,
      Fizz.Integrations.Library.Google.Slides.Actions.AddSlide
    ]
end
