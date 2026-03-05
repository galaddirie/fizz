import { computed } from 'vue';

import type { Workflow } from '@/types/workflow';

const getDraftSteps = (workflow: Workflow) => workflow.draft?.steps ?? [];
const getDraftConnections = (workflow: Workflow) => workflow.draft?.connections ?? [];

const sortStepIdsByOrder = (stepIds: string[], orderById: Record<string, number>) =>
  [...stepIds].sort((left, right) => {
    const leftOrder = orderById[left] ?? Number.MAX_SAFE_INTEGER;
    const rightOrder = orderById[right] ?? Number.MAX_SAFE_INTEGER;
    return leftOrder - rightOrder;
  });

const buildStepNameById = (workflow: Workflow): Record<string, string> =>
  getDraftSteps(workflow).reduce(
    (acc, step) => {
      if (step.id && step.name) {
        acc[step.id] = step.name;
      }
      return acc;
    },
    {} as Record<string, string>,
  );

const buildStepOrderById = (workflow: Workflow): Record<string, number> => {
  const stepIds = getDraftSteps(workflow).map(step => step.id);
  const inDegrees = new Map<string, number>();
  const adjacency = new Map<string, Set<string>>();

  stepIds.forEach(id => inDegrees.set(id, 0));

  for (const connection of getDraftConnections(workflow)) {
    const sourceId = connection.source_step_id;
    const targetId = connection.target_step_id;

    if (!inDegrees.has(sourceId)) inDegrees.set(sourceId, 0);
    if (!inDegrees.has(targetId)) inDegrees.set(targetId, 0);

    const targets = adjacency.get(sourceId) ?? new Set<string>();
    if (!targets.has(targetId)) {
      targets.add(targetId);
      adjacency.set(sourceId, targets);
      inDegrees.set(targetId, (inDegrees.get(targetId) ?? 0) + 1);
    }
  }

  const queue = stepIds.filter(id => (inDegrees.get(id) ?? 0) === 0);
  const sorted: string[] = [];

  while (queue.length > 0) {
    const current = queue.shift();
    if (!current) continue;
    sorted.push(current);

    const children = adjacency.get(current);
    if (!children) continue;

    children.forEach(child => {
      const next = (inDegrees.get(child) ?? 0) - 1;
      inDegrees.set(child, next);
      if (next === 0) {
        queue.push(child);
      }
    });
  }

  const visited = new Set(sorted);
  stepIds.forEach(id => {
    if (!visited.has(id)) sorted.push(id);
  });

  return sorted.reduce(
    (acc, id, index) => {
      acc[id] = index;
      return acc;
    },
    {} as Record<string, number>,
  );
};

const buildIncomingStepIdsByStepId = (
  workflow: Workflow,
  orderById: Record<string, number>,
): Record<string, string[]> => {
  const incoming = new Map<string, string[]>();

  for (const connection of getDraftConnections(workflow)) {
    const targetId = connection.target_step_id;
    const sourceId = connection.source_step_id;
    const list = incoming.get(targetId) ?? [];

    if (!list.includes(sourceId)) {
      list.push(sourceId);
    }

    incoming.set(targetId, list);
  }

  return getDraftSteps(workflow).reduce(
    (acc, step) => {
      acc[step.id] = sortStepIdsByOrder(incoming.get(step.id) ?? [], orderById);
      return acc;
    },
    {} as Record<string, string[]>,
  );
};

const buildUpstreamStepIdsByStepId = (workflow: Workflow): Record<string, string[]> => {
  const adjacency = new Map<string, string[]>();

  for (const connection of getDraftConnections(workflow)) {
    const list = adjacency.get(connection.target_step_id) ?? [];
    list.push(connection.source_step_id);
    adjacency.set(connection.target_step_id, list);
  }

  const getUpstream = (id: string, visited = new Set<string>()): Set<string> => {
    const parents = adjacency.get(id) ?? [];
    const result = new Set<string>();

    for (const parent of parents) {
      if (visited.has(parent)) continue;
      visited.add(parent);
      result.add(parent);

      for (const upstream of getUpstream(parent, visited)) {
        result.add(upstream);
      }
    }

    return result;
  };

  return getDraftSteps(workflow).reduce(
    (acc, step) => {
      acc[step.id] = Array.from(getUpstream(step.id));
      return acc;
    },
    {} as Record<string, string[]>,
  );
};

const buildIncomingConnectionsByTargetInputByStepId = (
  workflow: Workflow,
  orderById: Record<string, number>,
): Record<string, Record<string, string[]>> => {
  const incoming = new Map<string, Map<string, string[]>>();

  for (const connection of getDraftConnections(workflow)) {
    const targetId = connection.target_step_id;
    const sourceId = connection.source_step_id;
    const targetInput = connection.target_input || 'main';

    const byInput = incoming.get(targetId) ?? new Map<string, string[]>();
    const list = byInput.get(targetInput) ?? [];

    if (!list.includes(sourceId)) {
      list.push(sourceId);
    }

    byInput.set(targetInput, list);
    incoming.set(targetId, byInput);
  }

  return getDraftSteps(workflow).reduce(
    (acc, step) => {
      const byInput = incoming.get(step.id) ?? new Map<string, string[]>();
      const inputMap: Record<string, string[]> = {};

      for (const [targetInput, sourceIds] of byInput.entries()) {
        inputMap[targetInput] = sortStepIdsByOrder(sourceIds, orderById);
      }

      acc[step.id] = inputMap;
      return acc;
    },
    {} as Record<string, Record<string, string[]>>,
  );
};

export function useWorkflowGraph(workflow: () => Workflow) {
  const stepNameById = computed<Record<string, string>>(() => buildStepNameById(workflow()));
  const stepOrderById = computed<Record<string, number>>(() => buildStepOrderById(workflow()));
  const incomingStepIdsByStepId = computed<Record<string, string[]>>(() =>
    buildIncomingStepIdsByStepId(workflow(), stepOrderById.value),
  );
  const upstreamStepIdsByStepId = computed<Record<string, string[]>>(() =>
    buildUpstreamStepIdsByStepId(workflow()),
  );
  const incomingConnectionsByTargetInputByStepId = computed<
    Record<string, Record<string, string[]>>
  >(() => buildIncomingConnectionsByTargetInputByStepId(workflow(), stepOrderById.value));

  return {
    stepNameById,
    incomingStepIdsByStepId,
    incomingConnectionsByTargetInputByStepId,
    upstreamStepIdsByStepId,
  };
}
