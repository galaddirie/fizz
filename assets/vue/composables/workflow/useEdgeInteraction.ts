import type {
  Connection as VueFlowConnection,
  Edge,
  EdgeChange,
  GraphEdge,
  UpdateEdge,
  useVueFlow,
} from '@vue-flow/core';

import type { WorkflowEditorDispatch } from '@/features/workflow-editor/contracts/workflowEditor';
import type { EdgeData } from '@/shared/ui/workflow-scene/types';
import type { Connection } from '@/types/workflow';

type EdgeUpdatePayload = { edge: Edge<EdgeData>; connection: VueFlowConnection };

interface UseEdgeInteractionOptions {
  canEdit: () => boolean;
  getEdges: () => GraphEdge<EdgeData>[];
  updateEdge: UpdateEdge;
  onConnect: ReturnType<typeof useVueFlow>['onConnect'];
  onEdgesChange: ReturnType<typeof useVueFlow>['onEdgesChange'];
  applyEdgeChanges: (changes: EdgeChange[]) => GraphEdge<EdgeData>[];
  setEdges: (edges: Edge<EdgeData>[] | GraphEdge<EdgeData>[]) => void;
  getConnections: () => Connection[];
  dispatch: WorkflowEditorDispatch;
  isSyncingDraft: () => boolean;
}

export function useEdgeInteraction(options: UseEdgeInteractionOptions) {
  const pendingEdgeRemovalIds = new Set<string>();

  const isValidConnection = (connection: VueFlowConnection) => {
    if (connection.source === connection.target) return false;
    const currentEdges = options.getEdges();

    const hasPath = (current: string, target: string, visited: Set<string> = new Set()): boolean => {
      if (current === target) return true;
      if (visited.has(current)) return false;
      visited.add(current);
      const outgoing = currentEdges.filter(edge => edge.source === current);
      for (const edge of outgoing) {
        if (hasPath(edge.target, target, visited)) return true;
      }
      return false;
    };

    return !hasPath(connection.target, connection.source);
  };

  const resolveConnectionId = (edge: {
    id: string;
    source?: string;
    target?: string;
    sourceHandle?: string | null;
    targetHandle?: string | null;
  }) => {
    const connections = options.getConnections();
    const directMatch = connections.find(conn => conn.id === edge.id);
    if (directMatch) return directMatch.id;

    const sourceHandle = edge.sourceHandle ?? 'main';
    const targetHandle = edge.targetHandle ?? 'main';

    const endpointMatch = connections.find(
      conn =>
      conn.source_step_id === edge.source &&
      conn.target_step_id === edge.target &&
      conn.source_output === sourceHandle &&
      conn.target_input === targetHandle
    );

    if (!endpointMatch) {
      console.warn('No matching connection found for edge deletion', edge);
      return null;
    }

    return endpointMatch.id;
  };

  const handleEdgeUpdate = ({ edge, connection }: EdgeUpdatePayload) => {
    if (!options.canEdit()) return;
    if (!connection?.source || !connection?.target) return;
    if (!isValidConnection(connection)) {
      console.warn('Invalid connection: cycles are not allowed.');
      return;
    }

    const normalizedConnection = {
      ...connection,
      sourceHandle: connection.sourceHandle ?? edge.sourceHandle ?? 'main',
      targetHandle: connection.targetHandle ?? edge.targetHandle ?? 'main',
    };

    const resolvedEdge = options.getEdges().find(item => item.id === edge.id);
    if (!resolvedEdge) {
      console.warn('Could not find resolved edge for update');
      return;
    }

    options.updateEdge(resolvedEdge, normalizedConnection, false);
    const connectionId = resolveConnectionId(edge);
    if (connectionId) {
      options.dispatch({
        type: 'document.connection.remove',
        payload: { connection_id: connectionId },
      });
    }
    options.dispatch({
      type: 'document.connection.add',
      payload: {
        source_step_id: normalizedConnection.source,
        target_step_id: normalizedConnection.target,
        source_output: normalizedConnection.sourceHandle ?? null,
        target_input: normalizedConnection.targetHandle ?? null,
      },
    });
  };

  const resetPendingEdgeRemovals = () => {
    pendingEdgeRemovalIds.clear();
  };

  options.onConnect(params => {
    if (!options.canEdit()) return;
    if (!isValidConnection(params)) {
      console.warn('Invalid connection: cycles are not allowed.');
      return;
    }
    options.dispatch({
      type: 'document.connection.add',
      payload: {
        source_step_id: params.source,
        target_step_id: params.target,
        source_output: params.sourceHandle ?? 'main',
        target_input: params.targetHandle ?? 'main',
      },
    });
  });

  options.onEdgesChange(changes => {
    if (options.isSyncingDraft() || !options.canEdit()) return;

    const nextChanges: EdgeChange[] = [];

    for (const change of changes) {
      if (change.type === 'remove') {
        if (!pendingEdgeRemovalIds.has(change.id)) {
          pendingEdgeRemovalIds.add(change.id);
          const connectionId = resolveConnectionId(change);
          if (connectionId) {
            options.dispatch({
              type: 'document.connection.remove',
              payload: { connection_id: connectionId },
            });
          }
        }
      }

      nextChanges.push(change);
    }

    const nextEdges = options.applyEdgeChanges(nextChanges);
    options.setEdges(nextEdges);
  });

  return {
    isValidConnection,
    handleEdgeUpdate,
    resolveConnectionId,
    resetPendingEdgeRemovals,
  };
}
