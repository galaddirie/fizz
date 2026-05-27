defmodule Fizz.Integrations.Box do
  @moduledoc """
  Box product integration catalog entry.
  """

  use Fizz.Integrations.StaticIntegration,
    id: "box",
    display_name: "Box",
    provider_id: "box_oauth",
    actions: ["box_upload_file"],
    step_modules: [
      Fizz.Integrations.Box.Actions.UploadFile
    ]
end
