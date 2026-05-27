defmodule Fizz.Integrations.Google.Slides do
  @moduledoc """
  Google Slides product integration catalog entry.
  """

  use Fizz.Integrations.StaticIntegration,
    id: "google_slides",
    display_name: "Google Slides",
    provider_id: "google_oauth",
    actions: ["google_slides_create_presentation", "google_slides_add_slide"],
    step_modules: [
      Fizz.Integrations.Google.Slides.Actions.CreatePresentation,
      Fizz.Integrations.Google.Slides.Actions.AddSlide
    ]
end
