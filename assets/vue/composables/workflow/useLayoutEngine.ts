import type { Edge, GraphNode, Position, XYPosition } from '@vue-flow/core';

import { useLayout } from '@/lib/useLayout';
import {
  DEFAULT_NODE_DIMENSIONS,
  EDGE_LABEL_GAP,
  EDGE_LABEL_HALF_HEIGHT,
  EDGE_LABEL_HALF_WIDTH,
  EDGE_LABEL_POSITION,
} from '@/constants/layout';
import type { EdgeData, GroupNodeData, StepNodeData, WorkflowNodeData } from '@/types/workflow';
import type { WorkflowEditorEmits } from '@/types/workflowEditor';
import { buildGroupBoundsFromPositions, getAbsoluteNodePosition } from '@/lib/workflowGeometry';
import { isGroupNode, isStepNode } from '@/lib/workflowGuards';

type LayoutNode = {
  id: string;
  position: { x: number; y: number };
  targetPosition?: Position;
  sourcePosition?: Position;
  dimensions?: { width: number; height: number };
  data?: StepNodeData;
  parentNode?: string;
};

type LayoutBounds = { minX: number; minY: number; maxX: number; maxY: number };
type LayoutDirection = 'LR' | 'RL';

interface UseLayoutEngineOptions {
  canEdit: () => boolean;
  getNodes: () => GraphNode<WorkflowNodeData>[];
  getEdges: () => Edge<EdgeData>[];
  getSelectedNodes: () => GraphNode<WorkflowNodeData>[];
  updateNode: (id: string, changes: Partial<GraphNode<WorkflowNodeData>>) => void;
  emit: WorkflowEditorEmits;
}

export function useLayoutEngine(options: UseLayoutEngineOptions) {
  const { layout, previousDirection } = useLayout();

  const getNodeDimensions = (node: LayoutNode) => ({
    width: node.dimensions?.width || DEFAULT_NODE_DIMENSIONS.width,
    height: node.dimensions?.height || DEFAULT_NODE_DIMENSIONS.height,
  });

  const hasEdgeLabel = (node?: LayoutNode) => {
    const count = node?.data?.stats?.out;
    return !(count === undefined || count === null || count === 0);
  };

  const updateBounds = (bounds: LayoutBounds, x: number, y: number) => {
    bounds.minX = Math.min(bounds.minX, x);
    bounds.minY = Math.min(bounds.minY, y);
    bounds.maxX = Math.max(bounds.maxX, x);
    bounds.maxY = Math.max(bounds.maxY, y);
  };

  const getLayoutBounds = (nodes: LayoutNode[], edges: Edge<EdgeData>[]): LayoutBounds => {
    const bounds: LayoutBounds = { minX: Infinity, minY: Infinity, maxX: -Infinity, maxY: -Infinity };
    const nodeLookup = new Map(nodes.map(node => [node.id, node]));

    nodes.forEach(node => {
      const { width, height } = getNodeDimensions(node);
      updateBounds(bounds, node.position.x, node.position.y);
      updateBounds(bounds, node.position.x + width, node.position.y + height);
    });

    edges.forEach(edge => {
      const source = nodeLookup.get(edge.source);
      const target = nodeLookup.get(edge.target);
      if (!source || !target || !hasEdgeLabel(source)) return;

      const sourceSize = getNodeDimensions(source);
      const targetSize = getNodeDimensions(target);
      const sourceX = source.position.x + sourceSize.width;
      const sourceY = source.position.y + sourceSize.height / 2;
      const targetX = target.position.x;
      const targetY = target.position.y + targetSize.height / 2;

      const labelX = sourceX + (targetX - sourceX) * EDGE_LABEL_POSITION;
      const labelY = sourceY + (targetY - sourceY) * EDGE_LABEL_POSITION;

      updateBounds(bounds, labelX - EDGE_LABEL_HALF_WIDTH, labelY - EDGE_LABEL_HALF_HEIGHT);
      updateBounds(bounds, labelX + EDGE_LABEL_HALF_WIDTH, labelY + EDGE_LABEL_HALF_HEIGHT);
    });

    return bounds;
  };

  const alignLayoutPositions = (
    originalNodes: LayoutNode[],
    layoutNodes: LayoutNode[],
    edges: Edge<EdgeData>[],
    direction: LayoutDirection
  ): LayoutNode[] => {
    if (!originalNodes.length || !layoutNodes.length) return layoutNodes;

    const originalBounds = getLayoutBounds(originalNodes, edges);
    const layoutBounds = getLayoutBounds(layoutNodes, edges);
    const offset = {
      x: originalBounds.minX - layoutBounds.minX,
      y: originalBounds.minY - layoutBounds.minY,
    };

    if (direction === 'LR') {
      offset.x = originalBounds.maxX - layoutBounds.maxX;
    }

    return layoutNodes.map(node => ({
      ...node,
      position: { x: node.position.x + offset.x, y: node.position.y + offset.y },
    }));
  };

  const handleLayout = (optionsArg: { groupId?: string } = {}) => {
    if (!options.canEdit()) return;
    const stepNodes = options.getNodes().filter(isStepNode) as unknown as GraphNode<StepNodeData>[];
    if (!stepNodes.length) return;

    const groupNodes = options.getNodes().filter(isGroupNode) as unknown as GraphNode<GroupNodeData>[];
    const groupNodeById = new Map(groupNodes.map(node => [node.id, node]));
    const undoLabel = optionsArg.groupId
      ? `Tidy Group: ${groupNodeById.get(optionsArg.groupId)?.data?.name ?? 'Group'}`
      : 'Tidy Workflow';

    let nodesToLayout: LayoutNode[] = [];
    const groupsToResize = new Set<string>();

    if (optionsArg.groupId) {
      nodesToLayout = stepNodes
        .filter(node => node.parentNode === optionsArg.groupId)
        .map(node => ({
          ...node,
          position: getAbsoluteNodePosition(node),
        }));
      groupsToResize.add(optionsArg.groupId);
    } else {
      const selection = options.getSelectedNodes();
      const selectedSteps = selection.filter(isStepNode) as unknown as GraphNode<StepNodeData>[];
      const selectedGroups = selection.filter(isGroupNode) as unknown as GraphNode<GroupNodeData>[];

      if (selection.length > 1) {
        const stepsFromGroups = selectedGroups.flatMap(group =>
          stepNodes.filter(node => node.parentNode === group.id)
        );
        const combined = [...selectedSteps, ...stepsFromGroups];
        const unique = new Map(combined.map(node => [node.id, node]));
        nodesToLayout = Array.from(unique.values()).map(node => ({
          ...node,
          position: getAbsoluteNodePosition(node),
        }));

        nodesToLayout.forEach(node => {
          if (node.parentNode) groupsToResize.add(node.parentNode);
        });
        selectedGroups.forEach(group => groupsToResize.add(group.id));
      } else {
        nodesToLayout = stepNodes.map(node => ({
          ...node,
          position: getAbsoluteNodePosition(node),
        }));
        groupNodes.forEach(group => groupsToResize.add(group.id));
      }
    }

    if (!nodesToLayout.length) return;

    const nodeIds = new Set(nodesToLayout.map(node => node.id));
    const edgesToLayout = options
      .getEdges()
      .filter(edge => nodeIds.has(edge.source) && nodeIds.has(edge.target));

    const layoutDirection = (previousDirection.value === 'RL' ? 'RL' : 'LR') as LayoutDirection;
    let normalizedLayout = nodesToLayout;

    if (nodesToLayout.length > 1) {
      const nodeLookup = new Map(nodesToLayout.map(node => [node.id, node]));
      const hasEdgeLabels = edgesToLayout.some(edge => hasEdgeLabel(nodeLookup.get(edge.source)));
      const layoutNodes = layout(nodesToLayout, edgesToLayout, layoutDirection, {
        ranksep: hasEdgeLabels ? EDGE_LABEL_GAP : undefined,
      }) as LayoutNode[];
      normalizedLayout = alignLayoutPositions(nodesToLayout, layoutNodes, edgesToLayout, layoutDirection);
    }

    const layoutById = new Map(normalizedLayout.map(node => [node.id, node]));
    const desiredAbsolutePositions = new Map<string, XYPosition>();
    stepNodes.forEach(node => {
      desiredAbsolutePositions.set(node.id, getAbsoluteNodePosition(node));
    });
    normalizedLayout.forEach(node => {
      desiredAbsolutePositions.set(node.id, node.position);
    });

    const groupBoundsById = new Map<
      string,
      { x: number; y: number; width: number; height: number }
    >();
    const groupUpdates: Array<{
      group_id: string;
      position: { x: number; y: number; width: number; height: number };
    }> = [];
    const stepMoves: Array<{ step_id: string; position: { x: number; y: number } }> = [];
    groupsToResize.forEach(groupId => {
      const groupNode = groupNodeById.get(groupId);
      if (!groupNode) return;
      const groupSteps = stepNodes.filter(node => node.parentNode === groupId);
      const bounds = buildGroupBoundsFromPositions(groupSteps, desiredAbsolutePositions);
      if (!bounds) return;
      groupBoundsById.set(groupId, bounds);

      options.updateNode(groupId, {
        position: { x: bounds.x, y: bounds.y },
        style: { width: `${bounds.width}px`, height: `${bounds.height}px` },
      });
      groupUpdates.push({ group_id: groupId, position: bounds });
    });

    const currentGroupPositions = new Map<string, XYPosition>();
    groupNodes.forEach(group => {
      currentGroupPositions.set(group.id, getAbsoluteNodePosition(group));
    });

    stepNodes.forEach(node => {
      const shouldUpdate =
        layoutById.has(node.id) || (node.parentNode && groupBoundsById.has(node.parentNode));
      if (!shouldUpdate) return;

      const desiredAbsolute = desiredAbsolutePositions.get(node.id);
      if (!desiredAbsolute) return;

      if (node.parentNode) {
        const groupId = node.parentNode;
        const groupBounds = groupBoundsById.get(groupId);
        const groupPosition = groupBounds
          ? { x: groupBounds.x, y: groupBounds.y }
          : currentGroupPositions.get(groupId);
        if (!groupPosition) return;

        const relativePosition = {
          x: desiredAbsolute.x - groupPosition.x,
          y: desiredAbsolute.y - groupPosition.y,
        };
        const layoutNode = layoutById.get(node.id);
        const positionChanged =
          relativePosition.x !== node.position.x || relativePosition.y !== node.position.y;

        if (positionChanged || layoutNode) {
          options.updateNode(node.id, {
            position: relativePosition,
            targetPosition: layoutNode?.targetPosition,
            sourcePosition: layoutNode?.sourcePosition,
          });
        }
        if (positionChanged) {
          stepMoves.push({ step_id: node.id, position: relativePosition });
        }
      } else {
        const layoutNode = layoutById.get(node.id);
        const positionChanged =
          desiredAbsolute.x !== node.position.x || desiredAbsolute.y !== node.position.y;
        if (positionChanged || layoutNode) {
          options.updateNode(node.id, {
            position: desiredAbsolute,
            targetPosition: layoutNode?.targetPosition,
            sourcePosition: layoutNode?.sourcePosition,
          });
        }
        if (positionChanged) {
          stepMoves.push({ step_id: node.id, position: desiredAbsolute });
        }
      }
    });

    if (stepMoves.length || groupUpdates.length) {
      options.emit('tidy_layout', {
        steps: stepMoves,
        groups: groupUpdates,
        label: undoLabel,
      });
    }
  };

  return {
    handleLayout,
    alignLayoutPositions,
    getLayoutBounds,
  };
}
