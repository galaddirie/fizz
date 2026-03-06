import { computed } from "vue";
import type { Node, XYPosition } from "@vue-flow/core";

import {
  DEFAULT_GROUP_COLOR,
  DEFAULT_GROUP_DIMENSIONS,
  DEFAULT_GROUP_NAME_FONT_SIZE,
} from "@/constants/layout";
import { generateColor } from "@/lib/color";
import type {
  GroupNodeData,
  StepNodeData,
  WorkflowNodeData,
} from "@/shared/ui/workflow-scene/types";
import type {
  EditorState,
  StepExecution,
  StepType,
  UserPresence,
  Workflow,
} from "@/types/workflow";

interface UseWorkflowNodesOptions {
  workflow: () => Workflow;
  stepTypes: () => StepType[];
  stepExecutions: () => StepExecution[];
  editorState: () => EditorState | undefined;
  presences: () => UserPresence[];
  currentUserId: () => string | undefined;
  canEdit?: () => boolean;
  collabSeq?: () => number | undefined;
  groupingPreview?: () => {
    groupId?: string | null;
    stepIds?: string[];
    color?: string | null;
  };
}

type ItemStats = {
  isMultiItem: boolean;
  itemsTotal: number;
  completed: number;
  failed: number;
  running: number;
};

type GroupBounds = {
  x: number;
  y: number;
  width: number;
  height: number;
};

type GroupNodesResult = {
  groupNodes: Node<WorkflowNodeData>[];
  groupByStepId: Map<string, string>;
};

const buildStepTypeIndex = (stepTypes: StepType[]) => {
  const stepTypeById: Record<string, StepType> = {};

  for (const stepType of stepTypes) {
    stepTypeById[stepType.id] = stepType;
  }

  return stepTypeById;
};

const toTimestampMs = (value: unknown): number | null => {
  if (value instanceof Date) {
    return Number.isFinite(value.getTime()) ? value.getTime() : null;
  }

  if (typeof value === "number") {
    return Number.isFinite(value) ? value : null;
  }

  if (typeof value === "string") {
    const parsed = Date.parse(value);
    return Number.isFinite(parsed) ? parsed : null;
  }

  if (!value || typeof value !== "object") return null;

  const record = value as Record<string, unknown>;
  const year =
    typeof record.year === "number" && Number.isFinite(record.year)
      ? record.year
      : null;
  const month =
    typeof record.month === "number" && Number.isFinite(record.month)
      ? record.month
      : null;
  const day =
    typeof record.day === "number" && Number.isFinite(record.day)
      ? record.day
      : null;
  const hour =
    typeof record.hour === "number" && Number.isFinite(record.hour)
      ? record.hour
      : null;
  const minute =
    typeof record.minute === "number" && Number.isFinite(record.minute)
      ? record.minute
      : null;
  const second =
    typeof record.second === "number" && Number.isFinite(record.second)
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

  if (Array.isArray(microsecond) && typeof microsecond[0] === "number") {
    millisecond = Math.floor(microsecond[0] / 1000);
  } else if (typeof microsecond === "number" && Number.isFinite(microsecond)) {
    millisecond = Math.floor(microsecond / 1000);
  }

  const utcOffset =
    typeof record.utc_offset === "number" ? record.utc_offset : 0;
  const stdOffset =
    typeof record.std_offset === "number" ? record.std_offset : 0;

  return (
    Date.UTC(year, month - 1, day, hour, minute, second, millisecond) -
    (utcOffset + stdOffset) * 1000
  );
};

const sumRecordedDurations = (
  executions: StepExecution[]
): number | undefined => {
  const durations = executions
    .map((execution) => execution.duration_us)
    .filter(
      (duration): duration is number =>
        typeof duration === "number" && Number.isFinite(duration)
    );

  return durations.length > 0
    ? durations.reduce((total, duration) => total + duration, 0)
    : undefined;
};

const groupStepExecutionsByStepId = (stepExecutions: StepExecution[]) => {
  const executionsByStepId: Record<string, StepExecution[]> = {};

  for (const stepExecution of stepExecutions) {
    if (!executionsByStepId[stepExecution.step_id]) {
      executionsByStepId[stepExecution.step_id] = [];
    }

    executionsByStepId[stepExecution.step_id].push(stepExecution);
  }

  for (const executions of Object.values(executionsByStepId)) {
    executions.sort(
      (left, right) => (left.item_index ?? -1) - (right.item_index ?? -1)
    );
  }

  return executionsByStepId;
};

const buildPrimaryStepExecutionIndex = (
  stepExecutionsByStepId: Record<string, StepExecution[]>
) => {
  const executionByStepId: Record<string, StepExecution | undefined> = {};

  for (const [stepId, executions] of Object.entries(stepExecutionsByStepId)) {
    executionByStepId[stepId] = executions[0];
  }

  return executionByStepId;
};

const buildStepItemStatsIndex = (
  stepExecutionsByStepId: Record<string, StepExecution[]>
) => {
  const itemStatsByStepId: Record<string, ItemStats> = {};

  for (const [stepId, executions] of Object.entries(stepExecutionsByStepId)) {
    const firstExecution = executions[0];
    const itemsTotal = firstExecution?.items_total ?? executions.length;

    itemStatsByStepId[stepId] = {
      isMultiItem: itemsTotal > 1 || executions.length > 1,
      itemsTotal,
      completed: executions.filter(
        (execution) => execution.status === "completed"
      ).length,
      failed: executions.filter((execution) => execution.status === "failed")
        .length,
      running: executions.filter((execution) => execution.status === "running")
        .length,
    };
  }

  return itemStatsByStepId;
};

const buildTransientStepPositions = (
  presences: UserPresence[],
  currentUserId?: string
) => {
  const positions: Record<string, XYPosition> = {};

  for (const presence of presences) {
    if (presence.user.id === currentUserId || !presence.dragging_steps)
      continue;

    for (const [stepId, position] of Object.entries(presence.dragging_steps)) {
      positions[stepId] = position;
    }
  }

  return positions;
};

const buildTransientGroupBounds = (
  presences: UserPresence[],
  currentUserId?: string
) => {
  const boundsByGroupId: Record<string, GroupBounds> = {};

  for (const presence of presences) {
    if (presence.user.id === currentUserId || !presence.dragging_groups)
      continue;

    for (const [groupId, bounds] of Object.entries(presence.dragging_groups)) {
      boundsByGroupId[groupId] = bounds;
    }
  }

  return boundsByGroupId;
};

const resolveGroupDimensions = (
  previewBounds: GroupBounds | undefined,
  position: {
    x?: number;
    y?: number;
    width?: number;
    height?: number;
  }
) => ({
  width:
    typeof previewBounds?.width === "number" && previewBounds.width > 0
      ? previewBounds.width
      : typeof position.width === "number" && position.width > 0
      ? position.width
      : DEFAULT_GROUP_DIMENSIONS.width,
  height:
    typeof previewBounds?.height === "number" && previewBounds.height > 0
      ? previewBounds.height
      : typeof position.height === "number" && position.height > 0
      ? position.height
      : DEFAULT_GROUP_DIMENSIONS.height,
});

const resolveGroupPosition = (
  previewBounds: GroupBounds | undefined,
  position: {
    x?: number;
    y?: number;
    width?: number;
    height?: number;
  }
) => ({
  x:
    typeof previewBounds?.x === "number"
      ? previewBounds.x
      : typeof position.x === "number"
      ? position.x
      : 0,
  y:
    typeof previewBounds?.y === "number"
      ? previewBounds.y
      : typeof position.y === "number"
      ? position.y
      : 0,
});

const buildGroupNodes = (params: {
  groups: NonNullable<Workflow["draft"]>["groups"];
  canEdit: boolean;
  collabSeq?: number;
  groupingColor?: string;
  groupingTargetId: string | null;
  transientGroupBounds: Record<string, GroupBounds>;
}): GroupNodesResult => {
  const groupByStepId = new Map<string, string>();

  const groupNodes = params.groups.map((group) => {
    for (const stepId of group.step_ids || []) {
      groupByStepId.set(stepId, group.id);
    }

    const previewBounds = params.transientGroupBounds[group.id];
    const position = group.position || {};
    const dimensions = resolveGroupDimensions(previewBounds, position);
    const color = group.color || DEFAULT_GROUP_COLOR;
    const fontSize =
      typeof group.font_size === "number" && Number.isFinite(group.font_size)
        ? group.font_size
        : DEFAULT_GROUP_NAME_FONT_SIZE;

    const groupNode = {
      id: group.id,
      type: "group",
      class: "nopan",
      position: resolveGroupPosition(previewBounds, position),
      data: {
        id: group.id,
        name: group.name || "Group",
        step_ids: group.step_ids || [],
        collapsed: !!group.collapsed,
        color,
        font_size: fontSize,
        isGroupingTarget: params.groupingTargetId === group.id,
        groupingColor: params.groupingColor,
        collabSeq: params.collabSeq,
        canEdit: params.canEdit,
      },
      style: {
        width: `${dimensions.width}px`,
        height: `${dimensions.height}px`,
      },
      draggable: params.canEdit,
      selectable: true,
      connectable: false,
      deletable: false,
      zIndex: -10,
    } satisfies Node<GroupNodeData>;

    return groupNode as Node<WorkflowNodeData>;
  });

  return { groupNodes, groupByStepId };
};

const resolveSelectedBy = (
  presences: UserPresence[],
  currentUserId: string | undefined,
  stepId: string
) =>
  presences
    .filter(
      (presence) =>
        presence.user.id !== currentUserId &&
        presence.selected_steps?.includes(stepId)
    )
    .map((presence) => {
      const displayName =
        presence.user.name || presence.user.email || "Unknown User";

      return {
        id: presence.user.id,
        name: displayName,
        color: generateColor(displayName, 0),
      };
    });

const resolveDisplayStatus = (
  stepExecution: StepExecution | undefined,
  itemStats: ItemStats | undefined
) => {
  if (!itemStats?.isMultiItem) return stepExecution?.status;
  if (itemStats.failed > 0) return "failed";
  if (itemStats.running > 0) return "running";
  if (itemStats.completed === itemStats.itemsTotal) return "completed";
  return stepExecution?.status;
};

const resolveTotalDurationUs = (executions: StepExecution[]) => {
  if (executions.length === 0) return undefined;

  const fallbackDurationUs = sumRecordedDurations(executions);
  if (executions.length === 1) return fallbackDurationUs;

  const startedAts = executions
    .map((execution) => toTimestampMs(execution.started_at))
    .filter((value): value is number => value !== null);
  const completedAts = executions
    .map((execution) => toTimestampMs(execution.completed_at))
    .filter((value): value is number => value !== null);

  if (startedAts.length === 0 || completedAts.length === 0) {
    return fallbackDurationUs;
  }

  const earliestStartMs = Math.min(...startedAts);
  const latestCompleteMs = Math.max(...completedAts);

  return latestCompleteMs >= earliestStartMs
    ? (latestCompleteMs - earliestStartMs) * 1000
    : fallbackDurationUs;
};

const buildStepNodes = (params: {
  steps: NonNullable<Workflow["draft"]>["steps"];
  stepTypeById: Record<string, StepType | undefined>;
  stepExecutionsByStepId: Record<string, StepExecution[]>;
  stepExecutionByStepId: Record<string, StepExecution | undefined>;
  itemStatsByStepId: Record<string, ItemStats>;
  editorState?: EditorState;
  presences: UserPresence[];
  currentUserId?: string;
  canEdit: boolean;
  transientPositions: Record<string, XYPosition>;
  groupByStepId: Map<string, string>;
  groupingStepIds: Set<string>;
  groupingColor?: string;
}) =>
  params.steps.map((step) => {
    const stepType = params.stepTypeById[step.type_id];
    const stepExecution = params.stepExecutionByStepId[step.id];
    const itemStats = params.itemStatsByStepId[step.id];
    const executions = params.stepExecutionsByStepId[step.id] || [];
    const parentGroupId = params.groupByStepId.get(step.id);
    const isGroupingCandidate = params.groupingStepIds.has(step.id);
    const totalDurationUs = resolveTotalDurationUs(executions);

    const stepNode = {
      id: step.id,
      type: stepType?.node_role === "subnode" ? "subnode" : "step",
      class: "nopan",
      position: params.transientPositions[step.id] || step.position,
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
        status: resolveDisplayStatus(stepExecution, itemStats),
        stats:
          stepExecution && totalDurationUs !== undefined
            ? {
                duration_us: totalDurationUs,
                out: stepExecution.output_item_count,
              }
            : undefined,
        subnode_slots: stepType?.subnode_slots ?? [],
        itemStats,
        hasInput:
          stepType?.step_kind !== "trigger" &&
          stepType?.node_role !== "subnode",
        hasOutput: true,
        disabled: params.editorState?.disabled_steps?.includes(step.id),
        pinned: params.editorState?.pinned_outputs?.[step.id] !== undefined,
        locked_by: params.editorState?.step_locks?.[step.id],
        selected_by: resolveSelectedBy(
          params.presences,
          params.currentUserId,
          step.id
        ),
        isGroupingCandidate,
        groupingColor: isGroupingCandidate ? params.groupingColor : undefined,
        canEdit: params.canEdit,
      } satisfies StepNodeData,
    };

    return stepNode as Node<WorkflowNodeData>;
  });

export function useWorkflowNodes(options: UseWorkflowNodesOptions) {
  const stepTypeById = computed<Record<string, StepType | undefined>>(() =>
    buildStepTypeIndex(options.stepTypes())
  );

  const stepExecutionsByStepId = computed<Record<string, StepExecution[]>>(() =>
    groupStepExecutionsByStepId(options.stepExecutions())
  );

  const stepExecutionByStepId = computed<
    Record<string, StepExecution | undefined>
  >(() => buildPrimaryStepExecutionIndex(stepExecutionsByStepId.value));

  const stepItemStatsByStepId = computed<Record<string, ItemStats>>(() =>
    buildStepItemStatsIndex(stepExecutionsByStepId.value)
  );

  const transientPositions = computed<Record<string, XYPosition>>(() =>
    buildTransientStepPositions(options.presences(), options.currentUserId())
  );

  const transientGroupBounds = computed<Record<string, GroupBounds>>(() =>
    buildTransientGroupBounds(options.presences(), options.currentUserId())
  );

  const nodes = computed<Node<WorkflowNodeData>[]>(() => {
    const workflowDraft = options.workflow().draft;
    const groupingPreview = options.groupingPreview?.() ?? {};
    const canEdit = options.canEdit?.() ?? true;
    const { groupNodes, groupByStepId } = buildGroupNodes({
      groups: workflowDraft?.groups ?? [],
      canEdit,
      collabSeq: options.collabSeq?.(),
      groupingColor: groupingPreview.color ?? undefined,
      groupingTargetId: groupingPreview.groupId ?? null,
      transientGroupBounds: transientGroupBounds.value,
    });
    const stepNodes = buildStepNodes({
      steps: workflowDraft?.steps ?? [],
      stepTypeById: stepTypeById.value,
      stepExecutionsByStepId: stepExecutionsByStepId.value,
      stepExecutionByStepId: stepExecutionByStepId.value,
      itemStatsByStepId: stepItemStatsByStepId.value,
      editorState: options.editorState(),
      presences: options.presences(),
      currentUserId: options.currentUserId(),
      canEdit,
      transientPositions: transientPositions.value,
      groupByStepId,
      groupingStepIds: new Set(groupingPreview.stepIds || []),
      groupingColor: groupingPreview.color ?? undefined,
    });

    return [...groupNodes, ...stepNodes];
  });

  return { nodes, transientPositions, stepExecutionsByStepId };
}
