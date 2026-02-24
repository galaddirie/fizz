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

    // Filter nodes and edges. Subnodes are handled separately.
    const subnodeIds = new Set(nodes.filter(n => n.type === 'subnode').map(n => n.id));
    const mainNodes = nodes.filter(n => !subnodeIds.has(n.id));

    // A subnode connection is one where the target handle is not "main"
    const isSubnodeConn = (edge: Edge) =>
      edge.targetHandle && edge.targetHandle !== 'main';

    const mainEdges = edges.filter(
      edge => !subnodeIds.has(edge.source) && !subnodeIds.has(edge.target) && !isSubnodeConn(edge)
    );

    for (const node of mainNodes) {
      const graphNode = findNode(node.id);
      dagreGraph.setNode(node.id, {
        width: graphNode?.dimensions.width || 150,
        height: graphNode?.dimensions.height || 50,
      });
    }

    for (const edge of mainEdges) {
      dagreGraph.setEdge(edge.source, edge.target);
    }

    dagre.layout(dagreGraph);

    // Initial map of positioned nodes
    const nodePositionMap = new Map<string, { x: number; y: number }>();

    // Process main nodes
    const positionedMainNodes = mainNodes.map((node: Node) => {
      const nodeWithPosition = dagreGraph.node(node.id);
      const nodeWidth = nodeWithPosition.width || 150;

      const position = {
        x: normalizedDirection === 'LR' ? nodeWithPosition.x - nodeWidth : nodeWithPosition.x,
        y: nodeWithPosition.y,
      };

      nodePositionMap.set(node.id, position);

      return {
        ...node,
        targetPosition: isHorizontal ? Position.Left : Position.Top,
        sourcePosition: isHorizontal ? Position.Right : Position.Bottom,
        position,
      };
    });

    // Process subnodes
    const positionedSubNodes = nodes
      .filter(n => subnodeIds.has(n.id))
      .map(node => {
        // Find the edge that connects this subnode to its parent
        const parentEdge = edges.find(e => e.source === node.id && isSubnodeConn(e));
        const parentId = parentEdge?.target;
        const parentPos = parentId ? nodePositionMap.get(parentId) : null;
        const parentNode = parentId ? findNode(parentId) : null;

        let position = node.position;

        if (parentPos && parentNode) {
          const parentWidth = parentNode.dimensions.width;
          const parentHeight = parentNode.dimensions.height;

          // Find sibling subnodes for the same parent and slot
          const slotId = parentEdge?.targetHandle;
          const siblingEdges = edges.filter(
            e => e.target === parentId && e.targetHandle === slotId && isSubnodeConn(e)
          );
          const siblingIndex = siblingEdges.findIndex(e => e.source === node.id);

          // Position subnode below parent
          // Default to centering it under the parent if we don't have slot coordinates
          // (Actual slot positioning would require knowing slot locations, which are relative to the node)
          const verticalGap = 80;
          const subnodeHeight = 100;

          position = {
            x: parentPos.x + parentWidth / 2 - 75, // Assuming subnode width ~150
            y: parentPos.y + parentHeight + verticalGap + siblingIndex * (subnodeHeight + 20),
          };
        }

        return {
          ...node,
          targetPosition: Position.Top, // Subnode target is at the top
          sourcePosition: Position.Bottom, // Subnode source is at the bottom (for consistency)
          position,
        };
      });

    return [...positionedMainNodes, ...positionedSubNodes];
  }

  return { graph, layout, previousDirection };
}
