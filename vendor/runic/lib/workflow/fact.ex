defmodule Runic.Workflow.Fact do
  alias Runic.Workflow.Components
  defstruct [:hash, :value, :ancestry, meta: %{}]

  @type hash() :: integer() | binary()

  @type t() :: %__MODULE__{
          value: term(),
          hash: hash(),
          ancestry: {hash(), hash()},
          meta: map()
        }

  def new(params) do
    struct!(__MODULE__, params)
    |> maybe_set_hash()
  end

  defp maybe_set_hash(%__MODULE__{value: value, hash: nil, meta: meta} = fact) do
    hash_input = {value, fact.ancestry, item_index(meta)}
    %__MODULE__{fact | hash: Components.fact_hash(hash_input)}
  end

  defp maybe_set_hash(%__MODULE__{hash: hash} = fact)
       when not is_nil(hash),
       do: fact

  defp item_index(meta) when is_map(meta) do
    Map.get(meta, :item_index) || Map.get(meta, "item_index")
  end

  defp item_index(_meta), do: nil
end
