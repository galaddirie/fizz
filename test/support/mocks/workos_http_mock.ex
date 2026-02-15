defmodule Fizz.WorkOSHTTPMock do
  @moduledoc false

  @owner_key {__MODULE__, :owner}
  @store_key {__MODULE__, :store}

  def configure(owner, store_pid) when is_pid(owner) and is_pid(store_pid) do
    :persistent_term.put(@owner_key, owner)
    :persistent_term.put(@store_key, store_pid)
    :ok
  end

  def reset do
    :persistent_term.erase(@owner_key)
    :persistent_term.erase(@store_key)
    :ok
  end

  def put_responses(responses) when is_list(responses) do
    Agent.update(store_pid!(), fn _state -> responses end)
  end

  def request(opts) do
    notify(opts)

    Agent.get_and_update(store_pid!(), fn
      [response | rest] -> {response, rest}
      [] -> {{:error, :no_mocked_response}, []}
    end)
  end

  defp notify(opts) do
    case :persistent_term.get(@owner_key, nil) do
      owner when is_pid(owner) ->
        send(owner, {:workos_http_request, opts})
        :ok

      _ ->
        :ok
    end
  end

  defp store_pid! do
    case :persistent_term.get(@store_key, nil) do
      store_pid when is_pid(store_pid) -> store_pid
      _ -> raise "WorkOSHTTPMock is not configured"
    end
  end
end
