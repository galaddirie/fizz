import { computed } from 'vue';
import type { Node, XYPosition } from '@vue-flow/core';

import { generateColor } from '@/lib/color';
import { DEFAULT_GROUP_COLOR, DEFAULT_GROUP_DIMENSIONS } from '@/constants/layout';
import type {
  Workflow,
  StepType,
  StepExecution,
  EditorState,
  UserPresence,
  StepNodeData,
  GroupNodeData,
  WorkflowNodeData,
} from '@/types/workflow';

interface UseWorkflowNodesOptions {
  workflow: () => Workflow;
  stepTypes: () => StepType[];
  stepExecutions: () => StepExecution[];
  editorState: () => EditorState | undefined;
  presences: () => UserPresence[];
  currentUserId: () => string | undefined;
  canEdit?: () => boolean;
  onRunNode?: (stepId: string) => void;
  onUpdateGroup?: (
    groupId: string,
    changes: {
      name?: string;
      color?: string;
      position?: { x?: number; y?: number; width?: number; height?: number };
    }
  ) => void;
  onUpdateStep?: (stepId: string, changes: { name?: string }) => void;
  onMoveSteps?: (stepPositions: Record<string, XYPosition>) => void;
  onTogglePin?: (stepId: string, isPinned: boolean) => void;
  groupingPreview?: () => { groupId?: string | null; stepIds?: string[]; color?: string | null };
}

export function useWorkflowNodes(options: UseWorkflowNodesOptions) {
  const stepTypeById = computed<Record<string, StepType | undefined>>(() => {
    const map: Record<string, StepType> = {};
    for (const stepType of options.stepTypes()) {
      map[stepType.id] = stepType;
    }
    return map;
  });

  // Group all step executions by step_id (for multi-item fan-out steps)
  const stepExecutionsByStepId = computed<Record<string, StepExecution[]>>(() => {
    const map: Record<string, StepExecution[]> = {};
    for (const stepExecution of options.stepExecutions()) {
      if (!map[stepExecution.step_id]) {
        map[stepExecution.step_id] = [];
      }
      map[stepExecution.step_id].push(stepExecution);
    }
    // Sort by item_index within each group
    for (const stepId in map) {
      map[stepId].sort((a, b) => (a.item_index ?? -1) - (b.item_index ?? -1));
    }
    return map;
  });

  // Get the "primary" step execution for status display (first one, or single-item step)
  const stepExecutionByStepId = computed<Record<string, StepExecution | undefined>>(() => {
    const map: Record<string, StepExecution | undefined> = {};
    for (const [stepId, executions] of Object.entries(stepExecutionsByStepId.value)) {
      map[stepId] = executions[0];
    }
    return map;
  });

  // Compute item stats for multi-item steps
  const stepItemStatsByStepId = computed<
    Record<
      string,
      {
        isMultiItem: boolean;
        itemsTotal: number;
        completed: number;
        failed: number;
        running: number;
      }
    >
  >(() => {
    const map: Record<
      string,
      {
        isMultiItem: boolean;
        itemsTotal: number;
        completed: number;
        failed: number;
        running: number;
      }
    > = {};
    for (const [stepId, executions] of Object.entries(stepExecutionsByStepId.value)) {
      const firstExec = executions[0];
      const itemsTotal = firstExec?.items_total ?? executions.length;
      const isMultiItem = itemsTotal > 1 || executions.length > 1;

      map[stepId] = {
        isMultiItem,
        itemsTotal,
        completed: executions.filter(e => e.status === 'completed').length,
        failed: executions.filter(e => e.status === 'failed').length,
        running: executions.filter(e => e.status === 'running').length,
      };
    }
    return map;
  });

  const transientPositions = computed<Record<string, XYPosition>>(() => {
    const positions: Record<string, XYPosition> = {};
    const currentUserId = options.currentUserId();

    for (const presence of options.presences()) {
      if (presence.user.id === currentUserId || !presence.dragging_steps) continue;
      for (const [id, pos] of Object.entries(presence.dragging_steps)) {
        positions[id] = pos;
      }
    }

    return positions;
  });

  const nodes = computed<Node<WorkflowNodeData>[]>(() => {
    const steps = options.workflow().draft?.steps || [];
    const groups = options.workflow().draft?.groups || [];
    const stepTypes = stepTypeById.value;
    const stepExecutions = stepExecutionByStepId.value;
    const itemStats = stepItemStatsByStepId.value;
    const editorState = options.editorState();
    const presences = options.presences();
    const currentUserId = options.currentUserId();
    const canEdit = options.canEdit?.() ?? true;
    const onRunNode = options.onRunNode;
    const groupingPreview = options.groupingPreview?.() ?? {};
    const groupingStepIds = new Set(groupingPreview.stepIds || []);
    const groupingTargetId = groupingPreview.groupId ?? null;
    const groupingColor = groupingPreview.color ?? undefined;

    const groupByStepId = new Map<string, string>();
    const groupNodes = groups.map(group => {
      const position = group.position || {};
      const width =
        typeof position.width === 'number' && position.width > 0
          ? position.width
          : DEFAULT_GROUP_DIMENSIONS.width;
      const height =
        typeof position.height === 'number' && position.height > 0
          ? position.height
          : DEFAULT_GROUP_DIMENSIONS.height;
      const color = group.color || DEFAULT_GROUP_COLOR;

      for (const stepId of group.step_ids || []) {
        groupByStepId.set(stepId, group.id);
      }

      const node = {
        id: group.id,
        type: 'group',
        position: {
          x: typeof position.x === 'number' ? position.x : 0,
          y: typeof position.y === 'number' ? position.y : 0,
        },
        data: {
          id: group.id,
          name: group.name || 'Group',
          step_ids: group.step_ids || [],
          collapsed: !!group.collapsed,
          color,
          isGroupingTarget: groupingTargetId === group.id,
          groupingColor,
          onUpdate: canEdit ? options.onUpdateGroup : undefined,
          onMoveSteps: canEdit ? options.onMoveSteps : undefined,
          canEdit,
        },
        style: {
          width: `${width}px`,
          height: `${height}px`,
        },
        draggable: canEdit,
        selectable: true,
        connectable: false,
        deletable: false,
        zIndex: -10,
      } satisfies Node<GroupNodeData>;

      return node as Node<WorkflowNodeData>;
    });

    const stepNodes = steps.map(step => {
      const stepType = stepTypes[step.type_id];
      const stepExecution = stepExecutions[step.id];
      const stepItemStats = itemStats[step.id];
      const allStepExecutions = stepExecutionsByStepId.value[step.id] || [];
      const isPinned = editorState?.pinned_outputs?.[step.id] !== undefined;
      const isDisabled = editorState?.disabled_steps?.includes(step.id);
      const lockedBy = editorState?.step_locks?.[step.id];
      const parentGroupId = groupByStepId.get(step.id);
      const isGroupingCandidate = groupingStepIds.has(step.id);

      const selectedBy = presences
        .filter(p => p.user.id !== currentUserId && p.selected_steps?.includes(step.id))
        .map(p => {
          const displayName = p.user.name || p.user.email || 'Unknown User';
          return {
            id: p.user.id,
            name: displayName,
            color: generateColor(displayName, 0),
          };
        });

      // For multi-item steps, determine overall status from item stats
      let displayStatus = stepExecution?.status;
      if (stepItemStats?.isMultiItem) {
        if (stepItemStats.failed > 0 && stepItemStats.completed > 0) {
          // Partial failure - some completed, some failed
          displayStatus = 'failed';
        } else if (stepItemStats.running > 0) {
          displayStatus = 'running';
        } else if (stepItemStats.completed === stepItemStats.itemsTotal) {
          displayStatus = 'completed';
        }
      }

      // Calculate total duration for multi-item steps
      let totalDurationUs: number | undefined;
      if (allStepExecutions.length > 0) {
        if (allStepExecutions.length === 1) {
          // Single-item step - use the backend-calculated duration
          totalDurationUs = allStepExecutions[0].duration_us;
        } else {
          // Multi-item step - calculate total duration from earliest start to latest completion
          const startedAts = allStepExecutions
            .map(exec => exec.started_at)
            .filter(Boolean)
            .map(start => new Date(start!));

          const completedAts = allStepExecutions
            .map(exec => exec.completed_at)
            .filter(Boolean)
            .map(complete => new Date(complete!));

          if (startedAts.length > 0 && completedAts.length > 0) {
            const earliestStart = new Date(Math.min(...startedAts.map(d => d.getTime())));
            const latestComplete = new Date(Math.max(...completedAts.map(d => d.getTime())));
            totalDurationUs = (latestComplete.getTime() - earliestStart.getTime()) * 1000; // Convert to microseconds
          }
        }
      }

      const node = {
        id: step.id,
        type: 'step',
        position: transientPositions.value[step.id] || step.position,
        parentNode: parentGroupId,
        expandParent: parentGroupId ? true : undefined,
        zIndex: parentGroupId ? 20 : 10,
        data: {
          id: step.id,
          type_id: step.type_id,
          name: step.name,
          config: step.config,
          notes: step.notes,
          icon: stepType?.icon,
          category: stepType?.category,
          step_kind: stepType?.step_kind,
          status: displayStatus,
          stats:
            stepExecution && totalDurationUs !== undefined
              ? { duration_us: totalDurationUs, out: stepExecution.output_item_count }
              : undefined,
          itemStats: stepItemStats,
          hasInput: stepType?.step_kind !== 'trigger',
          hasOutput: true,
          disabled: isDisabled,
          pinned: isPinned,
          locked_by: lockedBy,
          selected_by: selectedBy,
          isGroupingCandidate,
          groupingColor: isGroupingCandidate ? groupingColor : undefined,
          onRunNode: canEdit ? onRunNode : undefined,
          onUpdate: canEdit ? options.onUpdateStep : undefined,
          onTogglePin: canEdit ? options.onTogglePin : undefined,
          canEdit,
        } satisfies StepNodeData,
      };

      return node as Node<WorkflowNodeData>;
    });

    return [...groupNodes, ...stepNodes];
  });

  return { nodes, transientPositions, stepExecutionsByStepId };
}
