defmodule Fizz.Integrations.Library.Box do
  @moduledoc """
  Box product integration catalog entry.
  """

  use Fizz.Integrations.Contracts.StaticIntegration,
    id: "box",
    display_name: "Box",
    provider_id: "box_oauth",
    actions: ["box_upload_file"],
    step_modules: [
      Fizz.Integrations.Library.Box.Actions.UploadFile
    ]
end
