import { computed } from 'vue';
import type { Node, XYPosition } from '@vue-flow/core';

import { generateColor } from '@/lib/color';
import {
  DEFAULT_GROUP_COLOR,
  DEFAULT_GROUP_DIMENSIONS,
  DEFAULT_GROUP_NAME_FONT_SIZE,
} from '@/constants/layout';
import type {
  Workflow,
  StepType,
  StepExecution,
  EditorState,
  UserPresence,
  StepNodeData,
  StepHandleQuickAddRequest,
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
      font_size?: number;
      position?: { x?: number; y?: number; width?: number; height?: number };
    }
  ) => void;
  onUpdateStep?: (stepId: string, changes: { name?: string }) => void;
  onMoveSteps?: (stepPositions: Record<string, XYPosition>) => void;
  onEmitInteraction?: (
    cursor?: XYPosition | null,
    dragging_steps?: Record<string, XYPosition> | null,
    dragging_groups?: Record<
      string,
      { x: number; y: number; width: number; height: number }
    > | null
  ) => void;
  onCommitDragLayout?: (payload: {
    txn_id: string;
    base_seq?: number;
    groups: Array<{
      group_id: string;
      position: { x: number; y: number; width: number; height: number };
    }>;
    step_positions: Record<string, XYPosition>;
    group_id_by_step_id: Record<string, string | null>;
  }) => void;
  collabSeq?: () => number | undefined;
  onToggleDisabled?: (stepId: string, isDisabled: boolean) => void;
  onTogglePin?: (stepId: string, isPinned: boolean) => void;
  onHandleQuickAdd?: (request: StepHandleQuickAddRequest) => void;
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

  const toTimestampMs = (value: unknown): number | null => {
    if (value instanceof Date) {
      return Number.isFinite(value.getTime()) ? value.getTime() : null;
    }

    if (typeof value === 'number') {
      return Number.isFinite(value) ? value : null;
    }

    if (typeof value === 'string') {
      const parsed = Date.parse(value);
      return Number.isFinite(parsed) ? parsed : null;
    }

    if (!value || typeof value !== 'object') return null;

    const record = value as Record<string, unknown>;
    const year =
      typeof record.year === 'number' && Number.isFinite(record.year) ? record.year : null;
    const month =
      typeof record.month === 'number' && Number.isFinite(record.month) ? record.month : null;
    const day = typeof record.day === 'number' && Number.isFinite(record.day) ? record.day : null;
    const hour =
      typeof record.hour === 'number' && Number.isFinite(record.hour) ? record.hour : null;
    const minute =
      typeof record.minute === 'number' && Number.isFinite(record.minute) ? record.minute : null;
    const second =
      typeof record.second === 'number' && Number.isFinite(record.second)
        ? record.second
        : null;

    if (
      year === null ||
      month === null ||
      day === null ||
      hour === null ||
      minute === null ||
      second === null
    ) {
      return null;
    }

    const microsecond = record.microsecond;
    let millisecond = 0;

    if (Array.isArray(microsecond) && typeof microsecond[0] === 'number') {
      millisecond = Math.floor(microsecond[0] / 1000);
    } else if (typeof microsecond === 'number' && Number.isFinite(microsecond)) {
      millisecond = Math.floor(microsecond / 1000);
    }

    const utcOffset = typeof record.utc_offset === 'number' ? record.utc_offset : 0;
    const stdOffset = typeof record.std_offset === 'number' ? record.std_offset : 0;

    return (
      Date.UTC(year, month - 1, day, hour, minute, second, millisecond) -
      (utcOffset + stdOffset) * 1000
    );
  };

  const sumRecordedDurations = (executions: StepExecution[]): number | undefined => {
    const durations = executions
      .map(execution => execution.duration_us)
      .filter((duration): duration is number => typeof duration === 'number' && Number.isFinite(duration));

    return durations.length > 0
      ? durations.reduce((total, duration) => total + duration, 0)
      : undefined;
  };

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

  const transientGroupBounds = computed<
    Record<string, { x: number; y: number; width: number; height: number }>
  >(() => {
    const boundsByGroupId: Record<
      string,
      { x: number; y: number; width: number; height: number }
    > = {};
    const currentUserId = options.currentUserId();

    for (const presence of options.presences()) {
      if (presence.user.id === currentUserId || !presence.dragging_groups) continue;
      for (const [groupId, bounds] of Object.entries(presence.dragging_groups)) {
        boundsByGroupId[groupId] = bounds;
      }
    }

    return boundsByGroupId;
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
    const previewGroupBoundsById = transientGroupBounds.value;

    const groupByStepId = new Map<string, string>();
    const groupNodes = groups.map(group => {
      const position = group.position || {};
      const previewBounds = previewGroupBoundsById[group.id];
      const previewX = previewBounds?.x;
      const previewY = previewBounds?.y;
      const previewWidth = previewBounds?.width;
      const previewHeight = previewBounds?.height;
      const width =
        typeof previewWidth === 'number' && previewWidth > 0
          ? previewWidth
          : typeof position.width === 'number' && position.width > 0
          ? position.width
          : DEFAULT_GROUP_DIMENSIONS.width;
      const height =
        typeof previewHeight === 'number' && previewHeight > 0
          ? previewHeight
          : typeof position.height === 'number' && position.height > 0
          ? position.height
          : DEFAULT_GROUP_DIMENSIONS.height;
      const color = group.color || DEFAULT_GROUP_COLOR;
      const fontSize =
        typeof group.font_size === 'number' && Number.isFinite(group.font_size)
          ? group.font_size
          : DEFAULT_GROUP_NAME_FONT_SIZE;

      for (const stepId of group.step_ids || []) {
        groupByStepId.set(stepId, group.id);
      }

      const node = {
        id: group.id,
        type: 'group',
        class: 'nopan',
        position: {
          x: typeof previewX === 'number' ? previewX : typeof position.x === 'number' ? position.x : 0,
          y: typeof previewY === 'number' ? previewY : typeof position.y === 'number' ? position.y : 0,
        },
        data: {
          id: group.id,
          name: group.name || 'Group',
          step_ids: group.step_ids || [],
          collapsed: !!group.collapsed,
          color,
          font_size: fontSize,
          isGroupingTarget: groupingTargetId === group.id,
          groupingColor,
          onUpdate: canEdit ? options.onUpdateGroup : undefined,
          onCommitDragLayout: canEdit ? options.onCommitDragLayout : undefined,
          onMoveSteps: canEdit ? options.onMoveSteps : undefined,
          onEmitInteraction: canEdit ? options.onEmitInteraction : undefined,
          collabSeq: options.collabSeq?.(),
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
        if (stepItemStats.failed > 0) {
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
        const fallbackDurationUs = sumRecordedDurations(allStepExecutions);

        if (allStepExecutions.length === 1) {
          // Single-item step - use the backend-calculated duration
          totalDurationUs = fallbackDurationUs;
        } else {
          // Multi-item step - calculate total duration from earliest start to latest completion
          const startedAts = allStepExecutions
            .map(exec => toTimestampMs(exec.started_at))
            .filter((value): value is number => value !== null);

          const completedAts = allStepExecutions
            .map(exec => toTimestampMs(exec.completed_at))
            .filter((value): value is number => value !== null);

          if (startedAts.length > 0 && completedAts.length > 0) {
            const earliestStartMs = Math.min(...startedAts);
            const latestCompleteMs = Math.max(...completedAts);

            totalDurationUs =
              latestCompleteMs >= earliestStartMs
                ? (latestCompleteMs - earliestStartMs) * 1000
                : fallbackDurationUs;
          } else {
            totalDurationUs = fallbackDurationUs;
          }
        }
      }

      const isSubnode = stepType?.node_role === 'subnode';

      const node = {
        id: step.id,
        type: isSubnode ? 'subnode' : 'step',
        class: 'nopan',
        position: transientPositions.value[step.id] || step.position,
        parentNode: parentGroupId,
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
          node_role: stepType?.node_role,
          status: displayStatus,
          stats:
            stepExecution && totalDurationUs !== undefined
              ? { duration_us: totalDurationUs, out: stepExecution.output_item_count }
              : undefined,
          subnode_slots: stepType?.subnode_slots ?? [],
          itemStats: stepItemStats,
          hasInput: stepType?.step_kind !== 'trigger' && stepType?.node_role !== 'subnode',
          hasOutput: true,
          disabled: isDisabled,
          pinned: isPinned,
          locked_by: lockedBy,
          selected_by: selectedBy,
          isGroupingCandidate,
          groupingColor: isGroupingCandidate ? groupingColor : undefined,
          onRunNode: canEdit ? onRunNode : undefined,
          onUpdate: canEdit ? options.onUpdateStep : undefined,
          onToggleDisabled: canEdit ? options.onToggleDisabled : undefined,
          onTogglePin: canEdit ? options.onTogglePin : undefined,
          onHandleQuickAdd: canEdit ? options.onHandleQuickAdd : undefined,
          canEdit,
        } satisfies StepNodeData,
      };

      return node as Node<WorkflowNodeData>;
    });

    return [...groupNodes, ...stepNodes];
  });

  return { nodes, transientPositions, stepExecutionsByStepId };
}
