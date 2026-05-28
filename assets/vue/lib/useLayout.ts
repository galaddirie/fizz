import dagre from '@dagrejs/dagre';
import { Position, useVueFlow, type Node, type Edge } from '@vue-flow/core';
import { ref } from 'vue';

type LayoutDirection = 'LR' | 'RL';
type SizedNode = Node & { dimensions?: { width?: number; height?: number } };
type SubnodeConnection = Edge & {
  source: string;
  target: string;
  targetHandle: string;
};

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
    const SUBNODE_VERTICAL_GAP = 86;
    const SUBNODE_STACK_VERTICAL_GAP = 22;
    const SUBNODE_MIN_CENTER_GAP = 150;

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

    // Filter nodes and edges. Only connected dependency nodes are handled in the dedicated subtree pass.
    const subnodeIds = new Set(nodes.filter(n => n.type === 'subnode').map(n => n.id));

    const nodeDimensions = (node: Node | null | undefined, fallback: { width: number; height: number }) => {
      const measured = node as SizedNode | null | undefined;
      return {
        width: measured?.dimensions?.width ?? fallback.width,
        height: measured?.dimensions?.height ?? fallback.height,
      };
    };

    const nodeById = new Map(nodes.map(node => [node.id, node]));
    const isSubnodeConn = (edge: Edge): edge is SubnodeConnection => {
      if (
        typeof edge.source !== 'string' ||
        typeof edge.target !== 'string' ||
        typeof edge.targetHandle !== 'string'
      ) {
        return false;
      }

      const targetNode = nodeById.get(edge.target);
      const targetData = targetNode?.data as
        | { dependency_inputs?: Array<{ id?: string | null }> }
        | undefined;

      return Array.isArray(targetData?.dependency_inputs)
        ? targetData.dependency_inputs.some(input => input?.id === edge.targetHandle)
        : false;
    };

    const subnodeConnections: SubnodeConnection[] = [];
    edges.forEach(edge => {
      if (!isSubnodeConn(edge)) return;
      if (!subnodeIds.has(edge.source)) return;
      subnodeConnections.push(edge);
    });
    const connectedSubnodeIds = new Set(subnodeConnections.map(edge => edge.source));
    const mainNodes = nodes.filter(n => !connectedSubnodeIds.has(n.id));

    const parentEdgeBySubnodeId = new Map<string, SubnodeConnection>(
      subnodeConnections.map(edge => [edge.source, edge])
    );
    const childrenByParentInput = new Map<string, Map<string, string[]>>();

    subnodeConnections.forEach(edge => {
      const inputId = edge.targetHandle;
      const byInput = childrenByParentInput.get(edge.target) ?? new Map<string, string[]>();
      const childIds = byInput.get(inputId) ?? [];
      childIds.push(edge.source);
      byInput.set(inputId, childIds);
      childrenByParentInput.set(edge.target, byInput);
    });

    const compareChildOrder = (leftId: string, rightId: string) => {
      const left = nodeById.get(leftId);
      const right = nodeById.get(rightId);
      if (!left && !right) return leftId.localeCompare(rightId);
      if (!left) return 1;
      if (!right) return -1;
      if (left.position.y !== right.position.y) return left.position.y - right.position.y;
      if (left.position.x !== right.position.x) return left.position.x - right.position.x;
      return left.id.localeCompare(right.id);
    };

    childrenByParentInput.forEach(inputMap => {
      inputMap.forEach((childIds, inputId) => {
        inputMap.set(inputId, childIds.sort(compareChildOrder));
      });
    });

    const branchHeightForMetricsCache = new Map<string, number>();
    const branchHeightForMetricsStack = new Set<string>();

    const getSubnodeSizeForMetrics = (nodeId: string) => {
      const node = nodeById.get(nodeId) ?? findNode(nodeId);
      return nodeDimensions(node, { width: 100, height: 64 });
    };

    const getSubnodeBranchHeightForMetrics = (nodeId: string): number => {
      const cached = branchHeightForMetricsCache.get(nodeId);
      if (cached !== undefined) return cached;

      const { height: nodeHeight } = getSubnodeSizeForMetrics(nodeId);
      if (branchHeightForMetricsStack.has(nodeId)) return nodeHeight;

      branchHeightForMetricsStack.add(nodeId);
      const inputMap = childrenByParentInput.get(nodeId);

      if (!inputMap || inputMap.size === 0) {
        branchHeightForMetricsStack.delete(nodeId);
        branchHeightForMetricsCache.set(nodeId, nodeHeight);
        return nodeHeight;
      }

      let deepestChildStack = 0;
      inputMap.forEach(childIds => {
        const inputHeight = childIds.reduce((total, childId, index) => {
          const branchHeight = getSubnodeBranchHeightForMetrics(childId);
          const siblingGap = index < childIds.length - 1 ? SUBNODE_STACK_VERTICAL_GAP : 0;
          return total + branchHeight + siblingGap;
        }, 0);
        deepestChildStack = Math.max(deepestChildStack, inputHeight);
      });

      const totalHeight = nodeHeight + SUBNODE_VERTICAL_GAP + deepestChildStack;
      branchHeightForMetricsStack.delete(nodeId);
      branchHeightForMetricsCache.set(nodeId, totalHeight);
      return totalHeight;
    };

    const mainSubtreeExtraHeightById = new Map<string, number>();
    mainNodes.forEach(node => {
      const inputMap = childrenByParentInput.get(node.id);
      if (!inputMap || inputMap.size === 0) {
        mainSubtreeExtraHeightById.set(node.id, 0);
        return;
      }

      let deepestInputStack = 0;
      inputMap.forEach(childIds => {
        const inputHeight = childIds.reduce((total, childId, index) => {
          const branchHeight = getSubnodeBranchHeightForMetrics(childId);
          const siblingGap = index < childIds.length - 1 ? SUBNODE_STACK_VERTICAL_GAP : 0;
          return total + branchHeight + siblingGap;
        }, 0);
        deepestInputStack = Math.max(deepestInputStack, inputHeight);
      });

      const extraHeight = deepestInputStack > 0 ? SUBNODE_VERTICAL_GAP + deepestInputStack : 0;
      mainSubtreeExtraHeightById.set(node.id, extraHeight);
    });

    const mainEdges = edges.filter(
      edge =>
        !connectedSubnodeIds.has(edge.source) &&
        !connectedSubnodeIds.has(edge.target) &&
        !isSubnodeConn(edge)
    );

    for (const node of mainNodes) {
      const graphNode = findNode(node.id);
      const { width, height } = nodeDimensions(graphNode, { width: 150, height: 50 });
      const extraHeight = mainSubtreeExtraHeightById.get(node.id) ?? 0;
      dagreGraph.setNode(node.id, {
        width,
        height: height + extraHeight,
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
      const reservedExtraHeight = mainSubtreeExtraHeightById.get(node.id) ?? 0;

      const position = {
        x: normalizedDirection === 'LR' ? nodeWithPosition.x - nodeWidth : nodeWithPosition.x,
        // Dagre reserves subtree space in node height; shift back so extra space sits below the card.
        y: nodeWithPosition.y - reservedExtraHeight / 2,
      };

      nodePositionMap.set(node.id, position);

      return {
        ...node,
        targetPosition:
          node.type === 'subnode' ? Position.Top : isHorizontal ? Position.Left : Position.Top,
        sourcePosition:
          node.type === 'subnode' ? Position.Top : isHorizontal ? Position.Right : Position.Bottom,
        position,
      };
    });

    const getOrderedInputIds = (parentId: string, inputMap: Map<string, string[]>) => {
      const parentNode = nodeById.get(parentId) ?? findNode(parentId);
      const parentData = parentNode?.data as
        | { dependency_inputs?: Array<{ id?: string | null }> }
        | undefined;
      const parentInputs = Array.isArray(parentData?.dependency_inputs)
        ? parentData.dependency_inputs
            .map((input: { id?: string | null }) => input?.id)
            .filter((inputId): inputId is string => !!inputId && inputId !== 'main')
        : [];
      const connectedInputIds = Array.from(inputMap.keys());

      return [
        ...parentInputs.filter(inputId => connectedInputIds.includes(inputId)),
        ...connectedInputIds.filter(inputId => !parentInputs.includes(inputId)).sort(),
      ];
    };

    const absolutePositionById = new Map(nodePositionMap);
    const positionedSubnodePositions = new Map<string, { x: number; y: number }>();
    const placedParentIds = new Set<string>();

    const subtreeHeightCache = new Map<string, number>();
    const subtreeHeightStack = new Set<string>();

    const getSubnodeSize = (nodeId: string) => {
      const node = nodeById.get(nodeId) ?? findNode(nodeId);
      return nodeDimensions(node, { width: 100, height: 64 });
    };

    const getBranchHeight = (nodeId: string): number => {
      const cached = subtreeHeightCache.get(nodeId);
      if (cached !== undefined) return cached;

      const { height: nodeHeight } = getSubnodeSize(nodeId);
      if (subtreeHeightStack.has(nodeId)) return nodeHeight;

      subtreeHeightStack.add(nodeId);
      const inputMap = childrenByParentInput.get(nodeId);

      if (!inputMap || inputMap.size === 0) {
        subtreeHeightStack.delete(nodeId);
        subtreeHeightCache.set(nodeId, nodeHeight);
        return nodeHeight;
      }

      let deepestChildStack = 0;
      inputMap.forEach(childIds => {
        const inputHeight = childIds.reduce((total, childId, index) => {
          const branchHeight = getBranchHeight(childId);
          const siblingGap = index < childIds.length - 1 ? SUBNODE_STACK_VERTICAL_GAP : 0;
          return total + branchHeight + siblingGap;
        }, 0);
        deepestChildStack = Math.max(deepestChildStack, inputHeight);
      });

      const totalHeight = nodeHeight + SUBNODE_VERTICAL_GAP + deepestChildStack;
      subtreeHeightStack.delete(nodeId);
      subtreeHeightCache.set(nodeId, totalHeight);
      return totalHeight;
    };

    const placeSubtree = (parentId: string) => {
      if (placedParentIds.has(parentId)) return;

      const inputMap = childrenByParentInput.get(parentId);
      if (!inputMap || inputMap.size === 0) {
        placedParentIds.add(parentId);
        return;
      }

      const parentNode = nodeById.get(parentId) ?? findNode(parentId);
      const parentPosition = absolutePositionById.get(parentId) ?? parentNode?.position;
      if (!parentNode || !parentPosition) return;

      absolutePositionById.set(parentId, parentPosition);
      const { width: parentWidth, height: parentHeight } = nodeDimensions(parentNode, {
        width: parentNode.type === 'subnode' ? 100 : 150,
        height: parentNode.type === 'subnode' ? 64 : 50,
      });

      const orderedInputIds = getOrderedInputIds(parentId, inputMap);
      if (!orderedInputIds.length) {
        placedParentIds.add(parentId);
        return;
      }

      const parentCenterX = parentPosition.x + parentWidth / 2;
      const distributedAnchors = orderedInputIds.map((_, index) => {
        const ratio = (index + 1) / (orderedInputIds.length + 1);
        return parentPosition.x + ratio * parentWidth;
      });

      for (let index = 1; index < distributedAnchors.length; index += 1) {
        const previous = distributedAnchors[index - 1];
        const current = distributedAnchors[index];
        if (current - previous < SUBNODE_MIN_CENTER_GAP) {
          distributedAnchors[index] = previous + SUBNODE_MIN_CENTER_GAP;
        }
      }

      const anchorCenterX =
        (distributedAnchors[0] + distributedAnchors[distributedAnchors.length - 1]) / 2;
      const recenterOffset = parentCenterX - anchorCenterX;
      const anchorByInput = new Map<string, number>();

      orderedInputIds.forEach((inputId, index) => {
        anchorByInput.set(inputId, distributedAnchors[index] + recenterOffset);
      });

      orderedInputIds.forEach(inputId => {
        const childIds = inputMap.get(inputId) ?? [];
        const inputAnchorX = anchorByInput.get(inputId) ?? parentCenterX;
        let nextY = parentPosition.y + parentHeight + SUBNODE_VERTICAL_GAP;

        childIds.forEach(childId => {
          const { width: childWidth } = getSubnodeSize(childId);
          const childPosition = {
            x: inputAnchorX - childWidth / 2,
            y: nextY,
          };

          positionedSubnodePositions.set(childId, childPosition);
          absolutePositionById.set(childId, childPosition);

          placeSubtree(childId);

          const branchHeight = getBranchHeight(childId);
          nextY += branchHeight + SUBNODE_STACK_VERTICAL_GAP;
        });
      });

      placedParentIds.add(parentId);
    };

    // Start from roots first (parents that are not themselves attached as subnodes),
    // then place any remaining orphaned parent chains.
    const rootParentIds = Array.from(childrenByParentInput.keys()).filter(
      parentId => !parentEdgeBySubnodeId.has(parentId)
    );
    rootParentIds.forEach(placeSubtree);
    Array.from(childrenByParentInput.keys()).forEach(placeSubtree);

    const positionedSubNodes = nodes
      .filter(n => connectedSubnodeIds.has(n.id))
      .map(node => {
        const position = positionedSubnodePositions.get(node.id) ?? node.position;

        return {
          ...node,
          targetPosition: Position.Top,
          sourcePosition: Position.Top,
          position,
        };
      });

    return [...positionedMainNodes, ...positionedSubNodes];
  }

  return { graph, layout, previousDirection };
}
