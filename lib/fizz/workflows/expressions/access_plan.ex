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

  defmodule CredentialFetch do
    @moduledoc false

    @enforce_keys [:provider, :credential_ref]
    defstruct [:provider, :credential_ref]

    @type t :: %__MODULE__{
            provider: String.t(),
            credential_ref: map()
          }
  end
end
