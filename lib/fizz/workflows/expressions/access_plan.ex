defmodule Fizz.Workflows.Expressions.AccessPlan do
  @moduledoc false

  defmodule Literal do
    @moduledoc false

    @enforce_keys [:value]
    defstruct [:value]

    @type t :: %__MODULE__{value: term()}
  end

  defmodule ValueExpression do
    @moduledoc false

    @enforce_keys [:path, :parsed, :filters]
    defstruct [:path, :parsed, :filters]

    @type t :: %__MODULE__{
            path: [String.t()],
            parsed: Solid.Template.t(),
            filters: [Solid.Filter.t()]
          }
  end

  defmodule TemplateExpression do
    @moduledoc false

    @enforce_keys [:parsed]
    defstruct [:parsed]

    @type t :: %__MODULE__{parsed: Solid.Template.t()}
  end

  defmodule PredicateExpression do
    @moduledoc false

    @enforce_keys [:parsed]
    defstruct [:parsed]

    @type t :: %__MODULE__{parsed: Solid.Template.t()}
  end

  defmodule SlotRef do
    @moduledoc """
    Compiled reference to a per-user slot binding declared in step config.

    Slots are typed declarations like `credential_ref` that resolve to
    a concrete value at runtime via the registered resolver for `kind`.
    """

    @enforce_keys [:kind, :slot_key, :step_id, :spec]
    defstruct [:kind, :slot_key, :step_id, :spec]

    @type t :: %__MODULE__{
            kind: String.t(),
            slot_key: String.t(),
            step_id: String.t() | nil,
            spec: map()
          }
  end
end
