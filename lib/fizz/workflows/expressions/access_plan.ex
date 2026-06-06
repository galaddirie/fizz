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

  defmodule CredentialRef do
    @moduledoc """
    Compiled reference to a per-user credential binding declared in step config.

    Credential declarations resolve to a credential_ref-shaped value at runtime
    through the run's credential resolver.
    """

    @enforce_keys [:requirement_key, :step_id, :provider, :auth_type]
    defstruct [:requirement_key, :step_id, :provider, :auth_type]

    @type t :: %__MODULE__{
            requirement_key: String.t(),
            step_id: String.t() | nil,
            provider: String.t(),
            auth_type: String.t()
          }
  end
end
