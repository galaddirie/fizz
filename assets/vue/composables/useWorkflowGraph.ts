import { computed } from 'vue';

import type { Workflow } from '@/types/workflow';

export function useWorkflowGraph(workflow: () => Workflow) {
  const stepNameById = computed<Record<string, string>>(() => {
    const steps = workflow().draft?.steps || [];
    return steps.reduce(
      (acc, step) => {
        if (step.id && step.name) {
          acc[step.id] = step.name;
        }
        return acc;
      },
      {} as Record<string, string>
    );
  });

  const stepOrderById = computed<Record<string, number>>(() => {
    const steps = workflow().draft?.steps || [];
    const connections = workflow().draft?.connections || [];
    const stepIds = steps.map(step => step.id);
    const inDegrees = new Map<string, number>();
    const adjacency = new Map<string, Set<string>>();

    stepIds.forEach(id => inDegrees.set(id, 0));

    for (const connection of connections) {
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
      {} as Record<string, number>
    );
  });

  const incomingStepIdsByStepId = computed<Record<string, string[]>>(() => {
    const steps = workflow().draft?.steps || [];
    const connections = workflow().draft?.connections || [];
    const orderById = stepOrderById.value;
    const incoming = new Map<string, string[]>();

    for (const connection of connections) {
      const targetId = connection.target_step_id;
      const sourceId = connection.source_step_id;
      const list = incoming.get(targetId) ?? [];

      if (!list.includes(sourceId)) {
        list.push(sourceId);
      }

      incoming.set(targetId, list);
    }

    return steps.reduce(
      (acc, step) => {
        const ordered = incoming.get(step.id) ?? [];
        acc[step.id] = [...ordered].sort((a, b) => {
          const aOrder = orderById[a] ?? Number.MAX_SAFE_INTEGER;
          const bOrder = orderById[b] ?? Number.MAX_SAFE_INTEGER;
          return aOrder - bOrder;
        });
        return acc;
      },
      {} as Record<string, string[]>
    );
  });

  const upstreamStepIdsByStepId = computed<Record<string, string[]>>(() => {
    const steps = workflow().draft?.steps || [];
    const connections = workflow().draft?.connections || [];

    const adjacency = new Map<string, string[]>();
    for (const connection of connections) {
      const list = adjacency.get(connection.target_step_id) ?? [];
      list.push(connection.source_step_id);
      adjacency.set(connection.target_step_id, list);
    }

    const getUpstream = (id: string, visited = new Set<string>()): Set<string> => {
      const parents = adjacency.get(id) || [];
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

    return steps.reduce(
      (acc, step) => {
        acc[step.id] = Array.from(getUpstream(step.id));
        return acc;
      },
      {} as Record<string, string[]>
    );
  });

  return { stepNameById, incomingStepIdsByStepId, upstreamStepIdsByStepId };
}
