defmodule Fizz.Integrations.StaticIntegration do
  @moduledoc """
  Small macro for product integrations whose catalog surface is static.

  Step modules remain the executable primitive. This macro removes the
  boilerplate from integrations that group catalog metadata and step modules.
  """

  @required_opts [:id, :display_name]

  defmacro __using__(opts) do
    for key <- @required_opts do
      unless Keyword.has_key?(opts, key) do
        raise ArgumentError, "#{key} is required for Fizz.Integrations.StaticIntegration"
      end
    end

    id = Keyword.fetch!(opts, :id)
    display_name = Keyword.fetch!(opts, :display_name)
    provider_id = Keyword.get(opts, :provider_id)
    actions = Keyword.get(opts, :actions, [])
    triggers = opts |> Keyword.get(:triggers, []) |> expand_modules(__CALLER__)
    step_modules = opts |> Keyword.get(:step_modules, []) |> expand_modules(__CALLER__)
    scopes = Keyword.get(opts, :scopes, %{})

    quote do
      @behaviour Fizz.Integrations.Integration

      @impl true
      def id, do: unquote(id)

      @impl true
      def display_name, do: unquote(display_name)

      @impl true
      def provider_id, do: unquote(provider_id)

      @impl true
      def actions, do: unquote(Macro.escape(actions))

      @impl true
      def triggers, do: unquote(Macro.escape(triggers))

      @impl true
      def step_modules, do: unquote(Macro.escape(step_modules))

      @impl true
      def required_scopes(operation) do
        Map.get(unquote(Macro.escape(scopes)), operation, [])
      end

      defoverridable required_scopes: 1
    end
  end

  defp expand_modules(modules, env) when is_list(modules) do
    Enum.map(modules, &Macro.expand(&1, env))
  end
end
