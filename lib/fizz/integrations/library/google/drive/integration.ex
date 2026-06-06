defmodule Fizz.Integrations.Library.Google.Drive do
  @moduledoc """
  Google Drive product integration catalog entry.
  """

  use Fizz.Integrations.Contracts.StaticIntegration,
    id: "google_drive",
    display_name: "Google Drive",
    provider_id: "google_oauth",
    actions: ["google_drive_upload_file"],
    step_modules: [
      Fizz.Integrations.Library.Google.Drive.Actions.UploadFile
    ]
end
