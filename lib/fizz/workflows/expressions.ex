defmodule Fizz.Workflows.Expressions do
  @moduledoc false

  alias Fizz.Workflows.Expressions.AccessPlan
  alias Fizz.Workflows.Expressions.Filters
  alias Solid.AccessLiteral
  alias Solid.Argument
  alias Solid.Context
  alias Solid.Object
  alias Solid.StandardFilter
  alias Solid.Variable

  @allowed_builtin_filters MapSet.new(~w(
    default
    append
    prepend
    upcase
    downcase
    strip
    replace
    split
    join
    first
    last
    size
    compact
    map
    sort
    sort_natural
    uniq
    where
    plus
    minus
    times
    divided_by
    modulo
    abs
    at_least
    at_most
    round
    ceil
    floor
    date
    slice
    truncate
    truncatewords
    url_encode
    url_decode
  ))

  @allowed_custom_filters MapSet.new(Filters.custom_filter_names())
  @allowed_filters MapSet.union(@allowed_builtin_filters, @allowed_custom_filters)
  @predicate_filters MapSet.new(Filters.predicate_filter_names())
  @quoted_step_access_regex ~r/steps\["((?:[^"\\]|\\.)*)"\]/

  @type validation_error :: String.t()

  @spec parse(String.t()) :: {:ok, Solid.Template.t()} | {:error, String.t()}
  def parse(expression_string) when is_binary(expression_string), do: parse(expression_string, [])

  @spec parse(String.t(), keyword()) :: {:ok, Solid.Template.t()} | {:error, String.t()}
  def parse(expression_string, opts) when is_binary(expression_string) and is_list(opts) do
    expression_string
    |> normalize_expression(opts)
    |> Solid.parse()
    |> case do
      {:ok, parsed} -> {:ok, parsed}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  @spec validate(String.t(), keyword()) ::
          {:ok, Solid.Template.t()} | {:error, [validation_error()]}
  def validate(expression_string, opts \\ []) when is_binary(expression_string) do
    with {:ok, parsed} <- parse(expression_string, opts) do
      errors =
        parsed
        |> validation_errors(opts)
        |> Enum.uniq()

      case errors do
        [] -> {:ok, parsed}
        _ -> {:error, errors}
      end
    end
  end

  @spec preview(String.t(), map()) :: {:ok, term()} | {:error, String.t()}
  def preview(expression_string, context) when is_binary(expression_string) and is_map(context) do
    with {:ok, parsed} <-
           parse(expression_string, step_name_to_id: step_name_to_id_from_context(context)),
         {:ok, plan} <- preview_access_plan(parsed) do
      {:ok, resolve(plan, context)}
    else
      {:error, reason} ->
        {:error, format_preview_error(reason)}
    end
  rescue
    error ->
      {:error, "Render error: #{Exception.message(error)}"}
  end

  @spec classify(term()) :: :literal | :value | :template | :predicate
  def classify(value) when not is_binary(value), do: :literal

  def classify(value) do
    if expression?(value) do
      case parse(value) do
        {:ok, parsed} -> classify_parsed(parsed)
        {:error, _reason} -> :template
      end
    else
      :literal
    end
  end

  @spec resolve(struct() | term(), map()) :: term()
  def resolve(%AccessPlan.Literal{value: value}, _context), do: value

  def resolve(%AccessPlan.ValueExpression{path: path, filters: []} = plan, context)
      when is_list(path) and path != [] do
    case direct_lookup(path, context) do
      {:ok, value} -> value
      :error -> resolve_value_expression(plan, context)
    end
  end

  def resolve(%AccessPlan.ValueExpression{} = plan, context),
    do: resolve_value_expression(plan, context)

  def resolve(%AccessPlan.TemplateExpression{parsed: parsed}, context) do
    parsed
    |> render_template(context)
    |> IO.iodata_to_binary()
  end

  def resolve(%AccessPlan.PredicateExpression{parsed: parsed}, context) do
    parsed
    |> resolve_predicate(context)
    |> truthy?()
  end

  def resolve(
        %AccessPlan.CredentialFetch{provider: provider, credential_ref: credential_ref},
        context
      ) do
    resolver =
      Map.get(context, :_credential_resolver) ||
        Map.get(context, "_credential_resolver") ||
        get_in(context, [:workflow, "_credential_resolver"]) ||
        get_in(context, [:workflow, :_credential_resolver])

    case resolver do
      resolver when is_function(resolver, 1) ->
        resolver.(Map.put(credential_ref, "provider", provider))

      _ ->
        nil
    end
  end

  def resolve(value, _context), do: value

  @spec to_access_plan(String.t(), keyword()) ::
          {:ok,
           AccessPlan.ValueExpression.t()
           | AccessPlan.TemplateExpression.t()
           | AccessPlan.PredicateExpression.t()}
          | {:error, [validation_error()]}
  def to_access_plan(expression_string, opts \\ []) when is_binary(expression_string) do
    with {:ok, parsed} <- validate(expression_string, opts) do
      case classify_parsed(parsed) do
        :value ->
          {:ok,
           %AccessPlan.ValueExpression{
             path: extract_literal_path(parsed),
             parsed: parsed,
             filters: single_object(parsed).filters
           }}

        :predicate ->
          {:ok, %AccessPlan.PredicateExpression{parsed: parsed}}

        :template ->
          {:ok, %AccessPlan.TemplateExpression{parsed: parsed}}
      end
    end
  end

  @spec dependencies(Solid.Template.t()) :: %{
          step_ids: MapSet.t(String.t()),
          runtime_keys: MapSet.t(atom())
        }
  def dependencies(%Solid.Template{} = parsed) do
    collect_variables(parsed)
    |> Enum.reduce(%{step_ids: MapSet.new(), runtime_keys: MapSet.new()}, fn
      %Variable{identifier: "steps"} = variable, acc ->
        case first_step_access(variable) do
          {:ok, step_id} ->
            %{acc | step_ids: MapSet.put(acc.step_ids, step_id)}

          :error ->
            acc
        end

      %Variable{identifier: namespace}, acc when namespace in ["workflow", "env"] ->
        %{acc | runtime_keys: MapSet.put(acc.runtime_keys, String.to_atom(namespace))}

      _variable, acc ->
        acc
    end)
  end

  @spec normalize_expression(String.t()) :: String.t()
  def normalize_expression(expression_string) when is_binary(expression_string),
    do: normalize_expression(expression_string, [])

  @spec normalize_expression(String.t(), keyword()) :: String.t()
  def normalize_expression(expression_string, opts)
      when is_binary(expression_string) and is_list(opts) do
    expression_string
    |> normalize_uuid_step_access()
    |> normalize_named_step_access(Keyword.get(opts, :step_name_to_id, %{}))
  end

  defp resolve_value_expression(%AccessPlan.ValueExpression{parsed: parsed}, context) do
    parsed
    |> single_object()
    |> then(fn object ->
      {result, _context} = render_object_value(object, context)
      result
    end)
  end

  defp resolve_predicate(parsed, context) do
    parsed
    |> single_object()
    |> then(fn object ->
      {result, _context} = render_object_value(object, context)
      result
    end)
  end

  defp render_template(parsed, context) do
    case Solid.render(parsed, solid_bindings(context), custom_filters: Filters) do
      {:ok, result, _errors} -> result
      {:error, _errors, partial_result} -> partial_result
    end
  end

  defp render_object_value(%Object{argument: argument, filters: filters}, context) do
    solid_context = %Context{vars: solid_bindings(context)}

    {:ok, result, solid_context} =
      Argument.get(argument, solid_context, filters, custom_filters: Filters)

    {result, solid_context}
  end

  defp solid_bindings(context) do
    input = Map.get(context, :input) || Map.get(context, "input") || %{}

    %{
      "input" => input,
      "json" => input,
      "steps" => Map.get(context, :steps) || Map.get(context, "steps") || %{},
      "workflow" => Map.get(context, :workflow) || Map.get(context, "workflow") || %{},
      "env" => Map.get(context, :env) || Map.get(context, "env") || %{}
    }
  end

  defp validation_errors(parsed, opts) do
    strict_filters? = Keyword.get(opts, :strict_filters, false)
    known_step_ids = Keyword.get(opts, :known_step_ids, :skip)

    []
    |> filter_validation_errors(parsed, strict_filters?)
    |> step_reference_errors(parsed, known_step_ids)
  end

  defp filter_validation_errors(errors, _parsed, false), do: errors

  defp filter_validation_errors(errors, parsed, true) do
    parsed
    |> collect_objects()
    |> Enum.flat_map(&validate_object_filters/1)
    |> Kernel.++(errors)
  end

  defp validate_object_filters(%Object{filters: filters}) do
    Enum.flat_map(filters, fn filter ->
      call_arity =
        1 + length(filter.positional_arguments) +
          if(map_size(filter.named_arguments) == 0, do: 0, else: 1)

      cond do
        not MapSet.member?(@allowed_filters, filter.function) ->
          ["unsupported filter `#{filter.function}`"]

        filter_exported?(Filters, filter.function, call_arity) ->
          []

        filter_known?(Filters, filter.function) ->
          ["wrong arity for filter `#{filter.function}`"]

        filter_exported?(StandardFilter, filter.function, call_arity) ->
          []

        filter_known?(StandardFilter, filter.function) ->
          ["wrong arity for filter `#{filter.function}`"]

        true ->
          ["unsupported filter `#{filter.function}`"]
      end
    end)
  end

  defp step_reference_errors(errors, _parsed, :skip), do: errors

  defp step_reference_errors(errors, parsed, known_step_ids) do
    known_step_ids = MapSet.new(known_step_ids)

    parsed
    |> collect_variables()
    |> Enum.flat_map(fn
      %Variable{identifier: "steps"} = variable ->
        case first_step_access(variable) do
          {:ok, step_id} ->
            if MapSet.member?(known_step_ids, step_id) do
              []
            else
              ["unknown step reference `#{step_id}`"]
            end

          :error ->
            ["step references must use a literal step id"]
        end

      _variable ->
        []
    end)
    |> Kernel.++(errors)
  end

  defp classify_parsed(%Solid.Template{parsed_template: [%Object{} = object]}) do
    if predicate_object?(object), do: :predicate, else: :value
  end

  defp classify_parsed(%Solid.Template{}), do: :template

  defp preview_access_plan(parsed) do
    case classify_parsed(parsed) do
      :value ->
        {:ok,
         %AccessPlan.ValueExpression{
           path: extract_literal_path(parsed),
           parsed: parsed,
           filters: single_object(parsed).filters
         }}

      :predicate ->
        {:ok, %AccessPlan.PredicateExpression{parsed: parsed}}

      :template ->
        {:ok, %AccessPlan.TemplateExpression{parsed: parsed}}
    end
  end

  defp format_preview_error("Parse error: " <> _ = message), do: message
  defp format_preview_error("Render error: " <> _ = message), do: message
  defp format_preview_error(reason), do: "Parse error: #{reason}"

  defp predicate_object?(%Object{filters: filters}) do
    Enum.any?(filters, &MapSet.member?(@predicate_filters, &1.function))
  end

  defp expression?(value), do: String.contains?(value, "{{") or String.contains?(value, "{%")

  defp single_object(%Solid.Template{parsed_template: [%Object{} = object]}), do: object

  defp extract_literal_path(parsed) do
    case single_object(parsed) do
      %Object{filters: []} = object ->
        literal_path_from_object(object)

      _object ->
        []
    end
  end

  defp literal_path_from_object(%Object{argument: %Variable{} = variable}) do
    literal_segments =
      Enum.reduce_while(variable.accesses, [], fn
        %AccessLiteral{value: value}, acc when is_binary(value) ->
          {:cont, [value | acc]}

        _access, _acc ->
          {:halt, :dynamic}
      end)

    case literal_segments do
      :dynamic ->
        []

      segments when is_binary(variable.identifier) ->
        [variable.identifier | Enum.reverse(segments)]

      _ ->
        []
    end
  end

  defp literal_path_from_object(_object), do: []

  defp direct_lookup([root | path], context) do
    root_value =
      case root do
        "input" -> Map.get(context, :input) || Map.get(context, "input")
        "json" -> Map.get(context, :input) || Map.get(context, "input")
        "steps" -> Map.get(context, :steps) || Map.get(context, "steps")
        "workflow" -> Map.get(context, :workflow) || Map.get(context, "workflow")
        "env" -> Map.get(context, :env) || Map.get(context, "env")
        _ -> nil
      end

    case lookup_path(root_value, path) do
      {:ok, value} -> {:ok, value}
      :error -> :error
    end
  end

  defp lookup_path(value, []), do: {:ok, value}

  defp lookup_path(value, [segment | rest]) do
    case lookup_segment(value, segment) do
      {:ok, next} -> lookup_path(next, rest)
      :error -> :error
    end
  end

  defp lookup_segment(value, segment) when is_map(value) do
    cond do
      Map.has_key?(value, segment) -> {:ok, Map.get(value, segment)}
      true -> :error
    end
  end

  defp lookup_segment(value, segment) when is_list(value) do
    case Integer.parse(segment) do
      {index, ""} ->
        case Enum.at(value, index) do
          nil when index >= length(value) -> :error
          item -> {:ok, item}
        end

      _ ->
        :error
    end
  end

  defp lookup_segment(_value, _segment), do: :error

  defp collect_objects(term) do
    term
    |> walk_ast([])
    |> Enum.filter(&match?(%Object{}, &1))
  end

  defp collect_variables(term) do
    term
    |> walk_ast([])
    |> Enum.filter(&match?(%Variable{}, &1))
  end

  defp walk_ast(list, acc) when is_list(list) do
    Enum.reduce(list, acc, &walk_ast(&1, &2))
  end

  defp walk_ast(%_{} = struct, acc) do
    acc =
      case struct do
        %Object{} -> [struct | acc]
        %Variable{} -> [struct | acc]
        _ -> acc
      end

    struct
    |> Map.from_struct()
    |> Enum.reduce(acc, fn {_key, value}, nested_acc -> walk_ast(value, nested_acc) end)
  end

  defp walk_ast(map, acc) when is_map(map) do
    Enum.reduce(map, acc, fn {_key, value}, nested_acc -> walk_ast(value, nested_acc) end)
  end

  defp walk_ast(_term, acc), do: acc

  defp first_step_access(%Variable{accesses: [%AccessLiteral{value: step_id} | _]})
       when is_binary(step_id),
       do: {:ok, step_id}

  defp first_step_access(_variable), do: :error

  defp filter_known?(module, filter_name) do
    Enum.any?(module.__info__(:functions), fn {fun, _arity} ->
      Atom.to_string(fun) == filter_name
    end)
  end

  defp filter_exported?(module, filter_name, arity) do
    Enum.any?(module.__info__(:functions), fn {fun, exported_arity} ->
      Atom.to_string(fun) == filter_name and exported_arity == arity
    end)
  end

  defp truthy?(value) when value in [nil, false, "", "false", "0", [], %{}], do: false
  defp truthy?(0), do: false
  defp truthy?(value) when is_float(value), do: value != 0.0
  defp truthy?(_value), do: true

  defp normalize_uuid_step_access(expression_string) do
    Regex.replace(
      ~r/steps\.([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})/,
      expression_string,
      ~s(steps["\\1"])
    )
  end

  defp normalize_named_step_access(expression_string, step_name_to_id)
       when not is_map(step_name_to_id) or map_size(step_name_to_id) == 0,
       do: expression_string

  defp normalize_named_step_access(expression_string, step_name_to_id) do
    Regex.replace(@quoted_step_access_regex, expression_string, fn full_match, encoded_name ->
      step_name =
        encoded_name
        |> then(&~s("#{&1}"))
        |> Jason.decode!()

      case Map.get(step_name_to_id, step_name) do
        step_id when is_binary(step_id) -> ~s(steps["#{step_id}"])
        _ -> full_match
      end
    end)
  end

  defp step_name_to_id_from_context(context) do
    case Map.get(context, :_step_name_to_id) || Map.get(context, "_step_name_to_id") do
      step_name_to_id when is_map(step_name_to_id) -> step_name_to_id
      _ -> %{}
    end
  end
end
