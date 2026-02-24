defmodule Fizz.Workflows.DagLayout do
  @moduledoc """
  Computes visual layout positions for workflow DAG steps.

  Uses a layered (Sugiyama-style) approach:
  1. Assign steps to layers via topological sort
  2. Order steps within layers to minimize edge crossings
  3. Assign x,y coordinates based on layer and position

  ## Usage

      steps = [%{id: "a", ...}, %{id: "b", ...}]
      connections = [%{source_step_id: "a", target_step_id: "b"}]

      layout = DagLayout.compute(steps, connections)
      # => %{
      #   "a" => %{x: 200, y: 100, layer: 0, index: 0},
      #   "b" => %{x: 200, y: 250, layer: 1, index: 0}
      # }
  """

  # TODO: delete this once we move ui to react
  alias Fizz.Graph

  @type step_id :: String.t()
  @type position :: %{
          x: number(),
          y: number(),
          layer: non_neg_integer(),
          index: non_neg_integer()
        }
  @type layout :: %{step_id() => position()}

  @default_opts [
    layer_height: 150,
    step_width: 200,
    step_height: 80,
    horizontal_gap: 60,
    vertical_gap: 40,
    padding_x: 100,
    padding_y: 80
  ]

  @doc """
  Computes layout positions for all steps in the workflow.

  ## Options

  - `:layer_height` - Vertical distance between layers (default: 150)
  - `:step_width` - Width of each step (default: 200)
  - `:step_height` - Height of each step (default: 80)
  - `:horizontal_gap` - Horizontal gap between steps in same layer (default: 60)
  - `:padding_x` - Left padding (default: 100)
  - `:padding_y` - Top padding (default: 80)
  """
  @spec compute(list(), list(), keyword()) :: layout()
  def compute(steps, connections, opts \\ [])

  def compute([], _connections, _opts), do: %{}

  def compute(steps, connections, opts) do
    opts = Keyword.merge(@default_opts, opts)

    # Separate subnode connections from main flow
    {subnode_connections, main_connections} =
      Enum.split_with(connections, &subnode_connection?/1)

    subnode_ids = Enum.map(subnode_connections, & &1.source_step_id) |> MapSet.new()

    # Main layout only includes non-subnodes
    main_steps = Enum.reject(steps, &MapSet.member?(subnode_ids, &1.id))

    # Build graph for main steps only
    graph = Graph.from_workflow!(main_steps, main_connections, validate: false)

    # Assign layers via longest-path layering
    layers = assign_layers(graph)

    # Group steps by layer
    steps_by_layer = group_by_layer(layers)

    # Order steps within layers
    ordered_layers = order_within_layers(steps_by_layer, graph)

    # Compute main positions
    layout = compute_positions(ordered_layers, opts)

    # Post-process to position subnodes
    position_subnodes(layout, subnode_connections, opts)
  end

  defp subnode_connection?(conn) do
    target_input = Map.get(conn, :target_input) || Map.get(conn, "target_input")
    target_input not in [nil, "main", :main, ""]
  end

  defp position_subnodes(layout, subnode_connections, opts) do
    vertical_gap = opts[:vertical_gap]
    step_height = opts[:step_height]

    # Group subnodes by parent
    subnodes_by_parent =
      Enum.group_by(subnode_connections, fn conn -> conn.target_step_id end)

    Enum.reduce(subnodes_by_parent, layout, fn {parent_id, conns}, acc ->
      case Map.get(acc, parent_id) do
        nil ->
          acc

        parent_pos ->
          # For now, we position subnodes in a column below the parent
          conns
          |> Enum.with_index()
          |> Enum.reduce(acc, fn {conn, idx}, inner_acc ->
            subnode_id = conn.source_step_id

            # Simple vertical offset
            x = parent_pos.x
            y = parent_pos.y + step_height + vertical_gap + idx * (step_height + vertical_gap)

            Map.put(inner_acc, subnode_id, %{
              x: x,
              y: y,
              layer: parent_pos.layer + 1,
              index: parent_pos.index,
              is_subnode: true
            })
          end)
      end
    end)
  end

  @doc """
  Returns layout metadata including dimensions and layer info.
  """
  @spec compute_with_metadata(list(), list(), keyword()) ::
          {layout(), %{width: number(), height: number(), layer_count: non_neg_integer()}}
  def compute_with_metadata(steps, connections, opts \\ []) do
    opts = Keyword.merge(@default_opts, opts)
    layout = compute(steps, connections, opts)

    if map_size(layout) == 0 do
      {layout, %{width: 400, height: 300, layer_count: 0}}
    else
      max_layer =
        layout
        |> Map.values()
        |> Enum.map(& &1.layer)
        |> Enum.max(fn -> 0 end)

      max_x =
        layout
        |> Map.values()
        |> Enum.map(&(&1.x + opts[:step_width]))
        |> Enum.max(fn -> 400 end)

      width = max_x + opts[:padding_x]
      height = (max_layer + 1) * opts[:layer_height] + opts[:padding_y] * 2

      {layout, %{width: width, height: height, layer_count: max_layer + 1}}
    end
  end

  @doc """
  Computes edge paths for SVG rendering.
  Returns a list of edge definitions with path data.
  """
  @spec compute_edges(list(), layout(), keyword()) :: list()
  def compute_edges(connections, layout, opts \\ []) do
    opts = Keyword.merge(@default_opts, opts)
    step_width = opts[:step_width]
    step_height = opts[:step_height]

    Enum.map(connections, fn conn ->
      source_pos = Map.get(layout, conn.source_step_id)
      target_pos = Map.get(layout, conn.target_step_id)

      if source_pos && target_pos do
        is_subnode_conn = subnode_connection?(conn)

        {x1, y1, x2, y2} =
          if is_subnode_conn do
            # Subnode to Parent: Start from TOP of source, end at BOTTOM of target
            {source_pos.x + step_width / 2, source_pos.y, target_pos.x + step_width / 2,
             target_pos.y + step_height}
          else
            # Main Flow: Start from bottom center of source, end at top center of target
            # (Assuming vertical DAG flavor here as per original code)
            {source_pos.x + step_width / 2, source_pos.y + step_height,
             target_pos.x + step_width / 2, target_pos.y}
          end

        # Create smooth bezier curve
        mid_y = (y1 + y2) / 2
        path = "M #{x1} #{y1} C #{x1} #{mid_y}, #{x2} #{mid_y}, #{x2} #{y2}"

        %{
          id: conn.id,
          source_step_id: conn.source_step_id,
          target_step_id: conn.target_step_id,
          path: path,
          x1: x1,
          y1: y1,
          x2: x2,
          y2: y2
        }
      else
        nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  # ============================================================================
  # Private: Layer Assignment (Longest Path)
  # ============================================================================

  defp assign_layers(%Graph{} = graph) do
    # Find root steps (no incoming edges)
    roots = Graph.roots(graph)

    # If no roots found (cycle or empty), use first vertex
    roots = if roots == [], do: Enum.take(Graph.vertex_ids(graph), 1), else: roots

    # BFS to assign layers
    initial_layers = Map.new(roots, &{&1, 0})
    queue = :queue.from_list(roots)

    assign_layers_bfs(queue, graph, initial_layers)
  end

  defp assign_layers_bfs(queue, graph, layers) do
    case :queue.out(queue) do
      {:empty, _} ->
        layers

      {{:value, step_id}, rest_queue} ->
        current_layer = Map.get(layers, step_id, 0)
        children = Graph.children(graph, step_id)

        {new_layers, new_queue} =
          Enum.reduce(children, {layers, rest_queue}, fn child_id, {l_acc, q_acc} ->
            child_layer = current_layer + 1
            existing_layer = Map.get(l_acc, child_id)

            if is_nil(existing_layer) or child_layer > existing_layer do
              {Map.put(l_acc, child_id, child_layer), :queue.in(child_id, q_acc)}
            else
              {l_acc, q_acc}
            end
          end)

        assign_layers_bfs(new_queue, graph, new_layers)
    end
  end

  # ============================================================================
  # Private: Layer Grouping and Ordering
  # ============================================================================

  defp group_by_layer(layers) do
    layers
    |> Enum.group_by(fn {_id, layer} -> layer end, fn {id, _layer} -> id end)
    |> Enum.sort_by(fn {layer, _steps} -> layer end)
    |> Enum.map(fn {layer, steps} -> {layer, steps} end)
  end

  defp order_within_layers(steps_by_layer, graph) do
    # Simple ordering: sort by number of connections (more connected = center)
    Enum.map(steps_by_layer, fn {layer, step_ids} ->
      sorted =
        Enum.sort_by(step_ids, fn id ->
          out_degree = Graph.out_degree(graph, id)
          in_degree = Graph.in_degree(graph, id)
          -(out_degree + in_degree)
        end)

      {layer, sorted}
    end)
  end

  # ============================================================================
  # Private: Position Computation
  # ============================================================================

  defp compute_positions(ordered_layers, opts) do
    layer_height = opts[:layer_height]
    step_width = opts[:step_width]
    horizontal_gap = opts[:horizontal_gap]
    padding_x = opts[:padding_x]
    padding_y = opts[:padding_y]

    # Find max width needed (for centering)
    max_layer_width =
      ordered_layers
      |> Enum.map(fn {_layer, steps} ->
        length(steps) * step_width + (length(steps) - 1) * horizontal_gap
      end)
      |> Enum.max(fn -> step_width end)

    Enum.reduce(ordered_layers, %{}, fn {layer, step_ids}, acc ->
      layer_width = length(step_ids) * step_width + (length(step_ids) - 1) * horizontal_gap
      start_x = padding_x + (max_layer_width - layer_width) / 2

      step_ids
      |> Enum.with_index()
      |> Enum.reduce(acc, fn {step_id, index}, inner_acc ->
        x = start_x + index * (step_width + horizontal_gap)
        y = padding_y + layer * layer_height

        Map.put(inner_acc, step_id, %{
          x: x,
          y: y,
          layer: layer,
          index: index
        })
      end)
    end)
  end
end
