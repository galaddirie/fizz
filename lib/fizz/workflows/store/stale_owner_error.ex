defmodule Fizz.Workflows.Store.StaleOwnerError do
  defexception [:run_id, :fence_token, message: "stale workflow owner"]

  @impl true
  def exception(opts) do
    run_id = Keyword.get(opts, :run_id)
    fence_token = Keyword.get(opts, :fence_token)

    message =
      "stale workflow owner for run #{inspect(run_id)} with fence token #{inspect(fence_token)}"

    %__MODULE__{run_id: run_id, fence_token: fence_token, message: message}
  end
end
