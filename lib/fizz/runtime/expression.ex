defmodule Fizz.Runtime.Expression do
  @moduledoc """
  Expression evaluation engine using Solid (Liquid templates).

  Provides secure, sandboxed expression evaluation for data flow between steps.
  Supports n8n-compatible syntax adapted for Liquid templates:

  ## Supported Variables

  - `{{ json }}` or `{{ json.field }}` - Current step input data
  - `{{ steps["StepName"].json }}` - Output from a specific step
  - `{{ steps.StepName.json }}` - Alternative dot notation
  - `{{ execution.id }}` - Execution metadata
  - `{{ workflow.id }}` - Workflow metadata
  - `{{ variables.name }}` - Workflow variables
  - `{{ metadata.trace_id }}` - Execution metadata
  - `{{ env.VARIABLE }}` - Allowed environment variables (configurable)

  ## Filters

  All standard Liquid filters plus custom ones:
  - `| json` - JSON encode
  - `| parse_json` - JSON decode
  - `| base64_encode` / `| base64_decode`
  - `| sha256` / `| md5` - Hashing
  - `| default: value` - Default if nil/empty
  - `| dig: "path.to.field"` - Deep access
  - `| pluck: "field"` - Extract field from list of maps
  - `| compact` - Remove nils from list
  - `| to_int` / `| to_float` / `| to_string`

  ## Examples

      # Simple field access
      Expression.evaluate("Hello {{ json.name }}!", execution)

      # Step output access
      Expression.evaluate("Status: {{ steps.HTTP.json.status }}", execution)

      # With filters
      Expression.evaluate("{{ json.items | size }}", execution)
      Expression.evaluate("{{ json.data | json }}", execution)

      # Conditionals
      Expression.evaluate("{% if json.active %}Yes{% else %}No{% endif %}", execution)

  ## Security

  - Sandboxed execution with no file system access
  - No code execution beyond Liquid templates
  - Configurable allowed environment variables
  - Strict variable access (unknown vars return nil or error)
  """

  alias Fizz.Runtime.Expression.{Context, Filters, Cache}
  alias Fizz.Executions.Execution

  @type eval_result :: {:ok, String.t()} | {:error, term()}
  @type eval_opts :: [
          strict_variables: boolean(),
          strict_filters: boolean(),
          timeout_ms: pos_integer(),
          timeout: pos_integer(),
          state_store: module() | map()
        ]

  @default_opts [
    strict_variables: false,
    strict_filters: true,
    timeout_ms: 5_000,
    state_store: %{}
  ]

  # Pattern to detect if a string contains Liquid expressions
  @expression_pattern ~r/\{\{.*?\}\}|\{%.*?%\}/s

  @doc """
  Evaluates a Liquid template string with the given execution context.

  Returns `{:ok, result}` or `{:error, reason}`.

  ## Options

  - `:strict_variables` - Return error for undefined variables (default: false)
  - `:strict_filters` - Return error for undefined filters (default: true)
  - `:timeout_ms` - Maximum evaluation time in ms (default: 1000)
  - `:state_store` - Module or map for runtime state
  """
  @spec evaluate(String.t(), Execution.t(), eval_opts()) :: eval_result()
  @spec evaluate(term(), map(), eval_opts()) :: eval_result()
  def evaluate(template, context, opts \\ [])

  def evaluate(template, %Execution{} = execution, opts) when is_binary(template) do
    opts = Keyword.merge(@default_opts, opts)

    unless contains_expression?(template) do
      {:ok, template}
    else
      vars = build_context(execution, opts)
      do_evaluate(template, vars, opts)
    end
  end

  def evaluate(template, vars, opts) when is_binary(template) and is_map(vars) do
    evaluate_with_vars(template, vars, opts)
  end

  def evaluate(data, %Execution{} = execution, opts) when is_map(data) or is_list(data) do
    evaluate_deep(data, execution, opts)
  end

  def evaluate(data, vars, opts) when (is_map(data) or is_list(data)) and is_map(vars) do
    evaluate_deep(data, vars, opts)
  end

  def evaluate(other, _context, _opts), do: {:ok, other}

  @doc """
  Evaluates a template with a raw variable map.

  Useful for testing or when you have pre-built variables.
  """
  @spec evaluate_with_vars(String.t(), map(), eval_opts()) :: eval_result()
  def evaluate_with_vars(template, vars, opts \\ []) when is_binary(template) and is_map(vars) do
    opts = Keyword.merge(@default_opts, opts)

    unless contains_expression?(template) do
      {:ok, template}
    else
      do_evaluate(template, vars, opts)
    end
  end

  @doc """
  Evaluates expressions in a nested data structure (map, list, or string).

  Recursively walks the structure and evaluates any string values that
  contain Liquid expressions.
  """
  @spec evaluate_deep(term(), Execution.t() | map(), eval_opts()) ::
          {:ok, term()} | {:error, term()}
  def evaluate_deep(data, context, opts \\ [])

  def evaluate_deep(data, %Execution{} = execution, opts) do
    opts = Keyword.merge(@default_opts, opts)
    vars = build_context(execution, opts)
    do_evaluate_deep_with_catch(data, vars, opts)
  end

  def evaluate_deep(data, vars, opts) when is_map(vars) do
    opts = Keyword.merge(@default_opts, opts)
    do_evaluate_deep_with_catch(data, vars, opts)
  end

  @doc """
  Checks if a string contains Liquid expressions.
  """
  @spec contains_expression?(String.t()) :: boolean()
  def contains_expression?(template) when is_binary(template) do
    Regex.match?(@expression_pattern, template)
  end

  @doc """
  Validates a template without evaluating it.

  Returns `:ok` if valid, `{:error, reason}` otherwise.
  """
  @spec validate(String.t()) :: :ok | {:error, term()}
  def validate(template) when is_binary(template) do
    case Solid.parse(template) do
      {:ok, _parsed} -> :ok
      {:error, error} -> {:error, format_parse_error(error)}
    end
  end

  @doc """
  Pre-compiles a template for repeated use.

  Returns `{:ok, compiled}` or `{:error, reason}`.
  """
  @spec compile(String.t()) :: {:ok, Solid.Template.t()} | {:error, term()}
  def compile(template) when is_binary(template) do
    case Cache.get_or_compile(template) do
      {:ok, compiled} -> {:ok, compiled}
      {:error, error} -> {:error, format_parse_error(error)}
    end
  end

  @doc """
  Renders a pre-compiled template with variables.
  """
  @spec render(Solid.Template.t(), map(), eval_opts()) :: eval_result()
  def render(compiled, vars, opts \\ []) when is_map(vars) do
    opts = Keyword.merge(@default_opts, opts)
    do_render(compiled, vars, opts)
  end

  # ============================================================================
  # Private Implementation
  # ============================================================================

  defp do_evaluate_deep_with_catch(data, vars, opts) do
    try do
      result = do_evaluate_deep(data, vars, opts)
      {:ok, result}
    catch
      {:expression_error, reason} -> {:error, reason}
    end
  end

  defp do_evaluate(template, vars, opts) do
    timeout = get_timeout_ms(opts)

    task =
      Task.async(fn ->
        case Cache.get_or_compile(template) do
          {:ok, compiled} ->
            do_render(compiled, vars, opts)

          {:error, reason} ->
            {:error, format_parse_error(reason)}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
      {:exit, reason} -> {:error, reason}
    end
  end

  defp do_render(compiled, vars, opts) do
    render_opts = [
      custom_filters: Filters,
      strict_variables: Keyword.get(opts, :strict_variables, false),
      strict_filters: Keyword.get(opts, :strict_filters, true)
    ]

    # Check for naked expression: exactly one object and nothing else
    # This allows preserving data types (arrays, maps, integers) when the template is just a single variable access
    case compiled.parsed_template do
      [%Solid.Object{argument: arg, filters: filters}] ->
        # Naked expression! Evaluate without stringifying.
        context = %Solid.Context{vars: vars}

        case Solid.Argument.get(arg, context, filters, render_opts) do
          {:ok, value, %Solid.Context{errors: []}} ->
            {:ok, value}

          {:ok, _value, %Solid.Context{errors: errors}} ->
            {:error, format_render_errors(errors)}
        end

      _ ->
        case Solid.render(compiled, vars, render_opts) do
          {:ok, iodata, _errors} ->
            {:ok, IO.iodata_to_binary(iodata)}

          {:ok, iodata} ->
            {:ok, IO.iodata_to_binary(iodata)}

          {:error, errors, _partial} ->
            {:error, format_render_errors(errors)}
        end
    end
  end

  defp do_evaluate_deep(data, vars, opts) when is_map(data) do
    Map.new(data, fn {k, v} -> {k, do_evaluate_deep(v, vars, opts)} end)
  end

  defp do_evaluate_deep(data, vars, opts) when is_list(data) do
    Enum.map(data, &do_evaluate_deep(&1, vars, opts))
  end

  defp do_evaluate_deep(data, vars, opts) when is_binary(data) do
    if contains_expression?(data) do
      case do_evaluate(data, vars, opts) do
        {:ok, result} -> result
        {:error, reason} -> throw({:expression_error, reason})
      end
    else
      data
    end
  end

  defp do_evaluate_deep(data, _vars, _opts), do: data

  defp build_context(%Execution{} = execution, opts) do
    state_store = Keyword.get(opts, :state_store)

    cond do
      is_map(state_store) ->
        Context.build(execution, state_store)

      is_atom(state_store) and Code.ensure_loaded?(state_store) ->
        step_outputs =
          if function_exported?(state_store, :outputs, 1) do
            case state_store.outputs(execution) do
              %{} = outputs -> outputs
              _ -> %{}
            end
          else
            %{}
          end

        current_input =
          if function_exported?(state_store, :current_input, 1) do
            state_store.current_input(execution)
          else
            nil
          end

        Context.build(execution, step_outputs, current_input)

      true ->
        Context.build(execution)
    end
  end

  defp get_timeout_ms(opts) do
    Keyword.get(opts, :timeout_ms) || Keyword.get(opts, :timeout) || 5_000
  end

  defp format_parse_error(%Solid.TemplateError{errors: [first | _]} = error) do
    meta = Map.get(first, :meta, %{})

    %{
      type: :parse_error,
      message: Exception.message(error),
      line: Map.get(meta, :line),
      column: Map.get(meta, :column)
    }
  end

  defp format_parse_error(%Solid.TemplateError{} = error) do
    %{type: :parse_error, message: Exception.message(error)}
  end

  defp format_parse_error(error) when is_binary(error) do
    %{type: :parse_error, message: error}
  end

  defp format_parse_error(error) do
    %{type: :parse_error, message: inspect(error)}
  end

  defp format_render_errors(errors) when is_list(errors) do
    messages = Enum.map(errors, &format_single_error/1)
    %{type: :render_error, errors: messages}
  end

  defp format_single_error(%{__struct__: _} = error) do
    Exception.message(error)
  end

  defp format_single_error(error), do: inspect(error)
end
