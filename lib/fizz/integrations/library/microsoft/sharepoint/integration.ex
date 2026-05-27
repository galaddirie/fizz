defmodule Fizz.Integrations.Library.Microsoft.SharePoint do
  @moduledoc """
  Microsoft SharePoint product integration catalog entry.
  """

  use Fizz.Integrations.Contracts.StaticIntegration,
    id: "sharepoint",
    display_name: "SharePoint",
    provider_id: "microsoft_oauth",
    actions: ["sharepoint_upload_file"],
    step_modules: [
      Fizz.Integrations.Library.Microsoft.SharePoint.Actions.UploadFile
    ]
end
