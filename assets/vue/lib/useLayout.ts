import dagre from '@dagrejs/dagre';
import { Position, useVueFlow, type Node, type Edge } from '@vue-flow/core';
import { ref } from 'vue';

type LayoutDirection = 'LR' | 'RL';

/**
 * Composable to run the layout algorithm on the graph.
 * It uses the `dagre` library to calculate the layout of the nodes and edges.
 */
export function useLayout() {
  const { findNode } = useVueFlow();

  const graph = ref(new dagre.graphlib.Graph());

  const previousDirection = ref('LR');

  function layout(
    nodes: Node[],
    edges: Edge[],
    direction: string,
    options: { ranksep?: number; nodesep?: number } = {}
  ) {
    // we create a new graph instance, in case some nodes/edges were removed, otherwise dagre would act as if they were still there
    const dagreGraph = new dagre.graphlib.Graph();

    graph.value = dagreGraph;

    dagreGraph.setDefaultEdgeLabel(() => ({}));

    const normalizedDirection: LayoutDirection = direction === 'RL' ? 'RL' : 'LR';
    const isHorizontal = normalizedDirection === 'LR' || normalizedDirection === 'RL';

    const graphOptions: Record<string, number | string> = { rankdir: normalizedDirection };
    if (options.ranksep !== undefined) graphOptions.ranksep = options.ranksep;
    if (options.nodesep !== undefined) graphOptions.nodesep = options.nodesep;
    dagreGraph.setGraph(graphOptions);

    previousDirection.value = normalizedDirection;

    for (const node of nodes) {
      // if you need width+height of nodes for your layout, you can use the dimensions property of the internal node (`GraphNode` type)
      const graphNode = findNode(node.id);

      dagreGraph.setNode(node.id, {
        width: graphNode?.dimensions.width || 150,
        height: graphNode?.dimensions.height || 50,
      });
    }

    for (const edge of edges) {
      dagreGraph.setEdge(edge.source, edge.target);
    }

    dagre.layout(dagreGraph);

    // set nodes with updated positions
    return nodes.map((node: Node) => {
      const nodeWithPosition = dagreGraph.node(node.id);
      const nodeWidth = nodeWithPosition.width || 150;

      return {
        ...node,
        targetPosition: isHorizontal ? Position.Left : Position.Top,
        sourcePosition: isHorizontal ? Position.Right : Position.Bottom,
        position: {
          x: normalizedDirection === 'LR' ? nodeWithPosition.x - nodeWidth : nodeWithPosition.x,
          y: nodeWithPosition.y,
        },
      };
    });
  }

  return { graph, layout, previousDirection };
}
