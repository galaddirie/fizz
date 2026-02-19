defmodule Fizz.Graph do
  @moduledoc """
  Directed graph data structure and operations.

  Provides a unified abstraction for DAG operations used throughout
  the workflow system including topological sorting, traversal,
  and subgraph extraction.

  ## Usage

      # From workflow steps and connections
      graph = Graph.from_workflow(steps, connections)

      # Query structure
      # Query structure
      Graph.parents(graph, "step_1")
      Graph.children(graph, "step_1")

      # Traversal
      Graph.upstream(graph, "step_1")   # all ancestors
      Graph.downstream(graph, "step_1") # all descendants

      # Algorithms
      {:ok, sorted} = Graph.topological_sort(graph)
      subgraph = Graph.subgraph(graph, ["step_1", "step_2"])
  """

  defstruct [
    :vertices,
    :edges,
    :adjacency,
    :reverse_adjacency
  ]

  @type vertex_id :: String.t()
  @type edge :: %{source: vertex_id(), target: vertex_id()}
  @type edge_tuple :: {vertex_id(), vertex_id()}

  @type t :: %__MODULE__{
          vertices: MapSet.t(vertex_id()),
          edges: [edge_tuple()],
          adjacency: %{vertex_id() => [vertex_id()]},
          reverse_adjacency: %{vertex_id() => [vertex_id()]}
        }

  # ============================================================================
  # Construction
  # ============================================================================

  @doc """
  Creates a new graph from vertex IDs and edge tuples.

  ## Examples

      iex> Graph.new(["a", "b", "c"], [{"a", "b"}, {"b", "c"}])
      %Graph{vertices: MapSet.new(["a", "b", "c"]), ...}
  """
  @spec new([vertex_id()], [edge_tuple()]) :: t()
  def new(vertex_ids, edges) when is_list(vertex_ids) and is_list(edges) do
    vertices = MapSet.new(vertex_ids)

    {adjacency, reverse_adjacency} =
      Enum.reduce(edges, {%{}, %{}}, fn {source, target}, {fwd, rev} ->
        fwd = Map.update(fwd, source, [target], &[target | &1])
        rev = Map.update(rev, target, [source], &[source | &1])
        {fwd, rev}
      end)

    %__MODULE__{
      vertices: vertices,
      edges: edges,
      adjacency: adjacency,
      reverse_adjacency: reverse_adjacency
    }
  end

  @doc """
  Creates a graph from workflow steps and connections.

  This is the primary constructor for workflow DAGs.

  ## Options

  - `:validate` - Whether to validate edges reference existing steps (default: true)

  ## Returns

  - `{:ok, graph}` - Successfully built graph
  - `{:error, {:invalid_edges, edges}}` - Some edges reference non-existent steps
  """
  @spec from_workflow(list(), list(), keyword()) :: {:ok, t()} | {:error, term()}
  def from_workflow(steps, connections, opts \\ []) do
    validate? = Keyword.get(opts, :validate, true)
    vertex_ids = Enum.map(steps, & &1.id)
    vertices = MapSet.new(vertex_ids)

    edges =
      Enum.map(connections, fn conn ->
        {conn.source_step_id, conn.target_step_id}
      end)

    if validate? do
      invalid =
        Enum.filter(edges, fn {src, tgt} ->
          not MapSet.member?(vertices, src) or not MapSet.member?(vertices, tgt)
        end)

      if invalid == [] do
        {:ok, new(vertex_ids, edges)}
      else
        {:error, {:invalid_edges, invalid}}
      end
    else
      {:ok, new(vertex_ids, edges)}
    end
  end

  @doc """
  Creates a graph from workflow, raising on error.
  """
  @spec from_workflow!(list(), list(), keyword()) :: t()
  def from_workflow!(steps, connections, opts \\ []) do
    case from_workflow(steps, connections, opts) do
      {:ok, graph} -> graph
      {:error, reason} -> raise "Failed to build graph: #{inspect(reason)}"
    end
  end

  # ============================================================================
  # Basic Queries
  # ============================================================================

  @doc "Returns the number of vertices in the graph."
  @spec vertex_count(t()) :: non_neg_integer()
  def vertex_count(%__MODULE__{vertices: vertices}), do: MapSet.size(vertices)

  @doc "Returns the number of edges in the graph."
  @spec edge_count(t()) :: non_neg_integer()
  def edge_count(%__MODULE__{edges: edges}), do: length(edges)

  @doc "Returns all vertex IDs as a list."
  @spec vertex_ids(t()) :: [vertex_id()]
  def vertex_ids(%__MODULE__{vertices: vertices}), do: MapSet.to_list(vertices)

  @doc "Checks if a vertex exists in the graph."
  @spec has_vertex?(t(), vertex_id()) :: boolean()
  def has_vertex?(%__MODULE__{vertices: vertices}, id), do: MapSet.member?(vertices, id)

  @doc "Checks if an edge exists between two vertices."
  @spec has_edge?(t(), vertex_id(), vertex_id()) :: boolean()
  def has_edge?(%__MODULE__{adjacency: adj}, source, target) do
    target in Map.get(adj, source, [])
  end

  @doc "Returns the direct parents (predecessors) of a vertex."
  @spec parents(t(), vertex_id()) :: [vertex_id()]
  def parents(%__MODULE__{reverse_adjacency: rev}, id) do
    Map.get(rev, id, [])
  end

  @doc "Returns the direct children (successors) of a vertex."
  @spec children(t(), vertex_id()) :: [vertex_id()]
  def children(%__MODULE__{adjacency: adj}, id) do
    Map.get(adj, id, [])
  end

  @doc "Returns the in-degree (number of incoming edges) for a vertex."
  @spec in_degree(t(), vertex_id()) :: non_neg_integer()
  def in_degree(graph, id), do: length(parents(graph, id))

  @doc "Returns the out-degree (number of outgoing edges) for a vertex."
  @spec out_degree(t(), vertex_id()) :: non_neg_integer()
  def out_degree(graph, id), do: length(children(graph, id))

  @doc "Returns all root vertices (no incoming edges)."
  @spec roots(t()) :: [vertex_id()]
  def roots(%__MODULE__{vertices: vertices, reverse_adjacency: rev}) do
    vertices
    |> MapSet.to_list()
    |> Enum.filter(fn id -> Map.get(rev, id, []) == [] end)
  end

  @doc "Returns all leaf vertices (no outgoing edges)."
  @spec leaves(t()) :: [vertex_id()]
  def leaves(%__MODULE__{vertices: vertices, adjacency: adj}) do
    vertices
    |> MapSet.to_list()
    |> Enum.filter(fn id -> Map.get(adj, id, []) == [] end)
  end

  # ============================================================================
  # Traversal
  # ============================================================================

  @doc """
  Returns all ancestors of a vertex (transitive upstream closure).

  Does not include the vertex itself.

  ## Example

      # Graph: a -> b -> c -> d
      Graph.upstream(graph, "d")
      #=> ["a", "b", "c"]  # order not guaranteed
  """
  @spec upstream(t(), vertex_id()) :: [vertex_id()]
  def upstream(%__MODULE__{reverse_adjacency: rev}, id) do
    traverse_closure(id, rev, MapSet.new())
    |> MapSet.delete(id)
    |> MapSet.to_list()
  end

  @doc """
  Returns all descendants of a vertex (transitive downstream closure).

  Does not include the vertex itself.

  ## Example

      # Graph: a -> b -> c -> d
      Graph.downstream(graph, "a")
      #=> ["b", "c", "d"]  # order not guaranteed
  """
  @spec downstream(t(), vertex_id()) :: [vertex_id()]
  def downstream(%__MODULE__{adjacency: adj}, id) do
    traverse_closure(id, adj, MapSet.new())
    |> MapSet.delete(id)
    |> MapSet.to_list()
  end

  @doc """
  Returns all vertices reachable from the given starting vertices.

  Includes the starting vertices themselves.
  """
  @spec reachable_from(t(), [vertex_id()]) :: MapSet.t(vertex_id())
  def reachable_from(%__MODULE__{adjacency: adj}, start_ids) do
    Enum.reduce(start_ids, MapSet.new(), fn id, acc ->
      MapSet.union(acc, traverse_closure(id, adj, MapSet.new()))
    end)
  end

  @doc """
  Returns all vertices that can reach the given target vertices.

  Includes the target vertices themselves.
  """
  @spec reaching(t(), [vertex_id()]) :: MapSet.t(vertex_id())
  def reaching(%__MODULE__{reverse_adjacency: rev}, target_ids) do
    Enum.reduce(target_ids, MapSet.new(), fn id, acc ->
      MapSet.union(acc, traverse_closure(id, rev, MapSet.new()))
    end)
  end

  @doc """
  Checks if `target` depends on `dependency` (dependency is upstream of target).
  """
  @spec depends_on?(t(), vertex_id(), vertex_id()) :: boolean()
  def depends_on?(graph, target, dependency) do
    dependency in upstream(graph, target)
  end

  defp traverse_closure(id, adjacency, visited) do
    if MapSet.member?(visited, id) do
      visited
    else
      visited = MapSet.put(visited, id)
      neighbors = Map.get(adjacency, id, [])
      Enum.reduce(neighbors, visited, &traverse_closure(&1, adjacency, &2))
    end
  end

  # ============================================================================
  # Algorithms
  # ============================================================================

  @doc """
  Performs topological sort using Kahn's algorithm.

  Returns vertices in dependency order (parents before children).

  ## Returns

  - `{:ok, sorted_ids}` - List of vertex IDs in topological order
  - `{:error, {:cycle_detected, involved_ids}}` - Graph contains a cycle
  """
  @spec topological_sort(t()) :: {:ok, [vertex_id()]} | {:error, {:cycle_detected, [vertex_id()]}}
  def topological_sort(%__MODULE__{} = graph) do
    in_degrees =
      graph.vertices
      |> MapSet.to_list()
      |> Map.new(fn id -> {id, in_degree(graph, id)} end)

    queue =
      in_degrees
      |> Enum.filter(fn {_id, degree} -> degree == 0 end)
      |> Enum.map(fn {id, _} -> id end)

    do_topological_sort(queue, in_degrees, graph.adjacency, [])
  end

  @doc """
  Performs topological sort, raising on cycle.
  """
  @spec topological_sort!(t()) :: [vertex_id()]
  def topological_sort!(graph) do
    case topological_sort(graph) do
      {:ok, sorted} -> sorted
      {:error, reason} -> raise "Topological sort failed: #{inspect(reason)}"
    end
  end

  defp do_topological_sort([], in_degrees, _adjacency, sorted) do
    remaining = Enum.filter(in_degrees, fn {_id, degree} -> degree > 0 end)

    if remaining == [] do
      {:ok, Enum.reverse(sorted)}
    else
      cycle_ids = Enum.map(remaining, fn {id, _} -> id end)
      {:error, {:cycle_detected, cycle_ids}}
    end
  end

  defp do_topological_sort([id | rest], in_degrees, adjacency, sorted) do
    children = Map.get(adjacency, id, [])

    {new_in_degrees, new_queue_additions} =
      Enum.reduce(children, {in_degrees, []}, fn child_id, {degrees, additions} ->
        new_degree = Map.get(degrees, child_id, 0) - 1
        new_degrees = Map.put(degrees, child_id, new_degree)

        if new_degree == 0 do
          {new_degrees, [child_id | additions]}
        else
          {new_degrees, additions}
        end
      end)

    new_in_degrees = Map.delete(new_in_degrees, id)

    do_topological_sort(
      rest ++ new_queue_additions,
      new_in_degrees,
      adjacency,
      [id | sorted]
    )
  end

  # ============================================================================
  # Subgraph Extraction
  # ============================================================================

  @doc """
  Extracts a subgraph containing only the specified vertices.

  Edges are included only if both endpoints are in the vertex set.
  """
  @spec subgraph(t(), [vertex_id()] | MapSet.t(vertex_id())) :: t()
  def subgraph(%__MODULE__{} = graph, vertex_ids) do
    vertex_set =
      case vertex_ids do
        %MapSet{} -> vertex_ids
        list when is_list(list) -> MapSet.new(list)
      end

    filtered_edges =
      Enum.filter(graph.edges, fn {src, tgt} ->
        MapSet.member?(vertex_set, src) and MapSet.member?(vertex_set, tgt)
      end)

    new(MapSet.to_list(vertex_set), filtered_edges)
  end

  @doc """
  Extracts the induced subgraph for executing to target steps.

  Returns a subgraph containing the targets and all their upstream dependencies,

  ## Options

  - `:exclude` - List of vertex IDs to exclude completely
  - `:include_targets` - Whether to include target steps (default: true)
  """
  @spec execution_subgraph(t(), [vertex_id()], keyword()) :: t()
  def execution_subgraph(%__MODULE__{} = graph, target_ids, opts \\ []) do
    exclude = Keyword.get(opts, :exclude, []) |> MapSet.new()
    include_targets = Keyword.get(opts, :include_targets, true)

    # Collect steps to run by traversing upstream from targets,
    steps_to_run = collect_upstream_with_boundary(graph, target_ids, MapSet.new(), exclude)

    # Remove targets if explicitly requested
    steps_to_run =
      if include_targets do
        steps_to_run
      else
        MapSet.difference(steps_to_run, MapSet.new(target_ids))
      end

    subgraph(graph, steps_to_run)
  end

  defp collect_upstream_with_boundary(graph, start_ids, boundary, exclude) do
    do_collect_upstream(graph, start_ids, boundary, exclude, MapSet.new())
  end

  defp do_collect_upstream(_graph, [], _boundary, _exclude, acc), do: acc

  defp do_collect_upstream(graph, [id | rest], boundary, exclude, acc) do
    cond do
      MapSet.member?(acc, id) ->
        do_collect_upstream(graph, rest, boundary, exclude, acc)

      MapSet.member?(exclude, id) ->
        do_collect_upstream(graph, rest, boundary, exclude, acc)

      MapSet.member?(boundary, id) ->
        # Include the boundary step but don't go upstream
        acc = MapSet.put(acc, id)
        do_collect_upstream(graph, rest, boundary, exclude, acc)

      true ->
        # Include step and recurse to parents
        acc = MapSet.put(acc, id)
        parents = parents(graph, id)
        do_collect_upstream(graph, parents ++ rest, boundary, exclude, acc)
    end
  end

  @doc """
  Extracts the downstream subgraph from a starting step.

  Returns a subgraph containing the start step and all its descendants.
  """
  @spec downstream_subgraph(t(), vertex_id()) :: t()
  def downstream_subgraph(%__MODULE__{} = graph, start_id) do
    descendants = downstream(graph, start_id)
    vertex_ids = [start_id | descendants]
    subgraph(graph, vertex_ids)
  end

  # ============================================================================
  # Validation
  # ============================================================================

  @doc """
  Validates the graph structure.

  Checks for:
  - Edges referencing non-existent vertices
  - Cycles (if `check_cycles: true`)

  ## Options

  - `:check_cycles` - Whether to check for cycles (default: true)
  """
  @spec validate(t(), keyword()) :: :ok | {:error, term()}
  def validate(%__MODULE__{} = graph, opts \\ []) do
    check_cycles = Keyword.get(opts, :check_cycles, true)

    with :ok <- validate_edges(graph),
         :ok <- if(check_cycles, do: validate_acyclic(graph), else: :ok) do
      :ok
    end
  end

  defp validate_edges(%__MODULE__{vertices: vertices, edges: edges}) do
    invalid =
      Enum.filter(edges, fn {src, tgt} ->
        not MapSet.member?(vertices, src) or not MapSet.member?(vertices, tgt)
      end)

    if invalid == [] do
      :ok
    else
      {:error, {:invalid_edges, invalid}}
    end
  end

  defp validate_acyclic(graph) do
    case topological_sort(graph) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # ============================================================================
  # Transformations
  # ============================================================================

  @doc "Adds a vertex to the graph."
  @spec add_vertex(t(), vertex_id()) :: t()
  def add_vertex(%__MODULE__{vertices: vertices} = graph, id) do
    %{graph | vertices: MapSet.put(vertices, id)}
  end

  @doc "Removes a vertex and all its edges from the graph."
  @spec remove_vertex(t(), vertex_id()) :: t()
  def remove_vertex(%__MODULE__{} = graph, id) do
    new_vertices = MapSet.delete(graph.vertices, id)
    new_edges = Enum.reject(graph.edges, fn {src, tgt} -> src == id or tgt == id end)
    new(MapSet.to_list(new_vertices), new_edges)
  end

  @doc "Adds an edge to the graph."
  @spec add_edge(t(), vertex_id(), vertex_id()) :: t()
  def add_edge(%__MODULE__{} = graph, source, target) do
    new_edges = [{source, target} | graph.edges]
    new(MapSet.to_list(graph.vertices), new_edges)
  end

  @doc "Removes an edge from the graph."
  @spec remove_edge(t(), vertex_id(), vertex_id()) :: t()
  def remove_edge(%__MODULE__{} = graph, source, target) do
    new_edges = Enum.reject(graph.edges, fn {s, t} -> s == source and t == target end)
    new(MapSet.to_list(graph.vertices), new_edges)
  end

  # ============================================================================
  # Inspection
  # ============================================================================

  defimpl Inspect do
    def inspect(%Fizz.Graph{} = graph, _opts) do
      "#Graph<#{MapSet.size(graph.vertices)} vertices, #{length(graph.edges)} edges>"
    end
  end
end
