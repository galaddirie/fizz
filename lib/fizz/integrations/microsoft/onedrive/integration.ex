defmodule Fizz.Integrations.Microsoft.OneDrive do
  @moduledoc """
  Microsoft OneDrive product integration catalog entry.
  """

  use Fizz.Integrations.StaticIntegration,
    id: "onedrive",
    display_name: "OneDrive",
    provider_id: "microsoft_oauth",
    actions: ["onedrive_upload_file"],
    step_modules: [
      Fizz.Integrations.Microsoft.OneDrive.Actions.UploadFile
    ]
end
