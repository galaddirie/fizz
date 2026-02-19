<script setup lang="ts">
import { ref, computed, watch } from 'vue';
import { watchDebounced } from '@vueuse/core';
import type { Node } from '@vue-flow/core';
import ExpressionPreviewError from './ExpressionPreviewError.vue';
import type {
  EditorState,
  Execution,
  StepExecution,
  StepExecutionStatus,
  StepNodeData,
  StepType,
} from '@/types/workflow';

interface ErrorPayload {
  type: 'parse_error' | 'render_error';
  message?: string;
  errors?: string[];
  line?: number;
  column?: number;
  text: string;
}
import {
  ArrowRightOnRectangleIcon,
  BoltIcon,
  CpuChipIcon,
  VariableIcon,
  GlobeAltIcon,
  PencilIcon,
  BookmarkIcon,
} from '@heroicons/vue/24/outline';
import { unwrapData, formatDataForDisplay } from '@/lib/dataUtils';

type ConfigSchemaField = {
  title?: string;
  type?: string;
  format?: string;
  default?: unknown;
};

type ConfigSchema = {
  properties?: Record<string, ConfigSchemaField>;
};

interface Props {
  node: Node<StepNodeData> | null;
  isOpen: boolean;
  canEdit?: boolean;
  stepType?: StepType | null;
  execution?: Execution | null;
  stepExecutions?: StepExecution[];
  expressionPreviews?: Record<string, unknown>;
  editorState?: EditorState;
  stepNameById?: Record<string, string>;
  incomingStepIds?: Record<string, string[]>;
  upstreamStepIds?: Record<string, string[]>;
}

const props = defineProps<Props>();
const emit = defineEmits([
  'close',
  'save',
  'preview_expression',
  'toggle_webhook_test',
  'pin_output',
  'unpin_output',
  'run_node',
]);

const activeTab = ref<'config' | 'output' | 'pinned'>('config');
const fieldModes = ref<Record<string, 'literal' | 'expression'>>({});
const fieldValues = ref<Record<string, unknown>>({});
const searchQuery = ref('');
const isEditingName = ref(false);
const editName = ref('');
const canEdit = computed(() => props.canEdit ?? true);

// State for unsaved changes tracking
const originalValues = ref<Record<string, unknown>>({});
const originalName = ref('');
const showCloseConfirmation = ref(false);

const hasUnsavedChanges = computed(() => {
  if (!canEdit.value) return false;
  
  // Check if name changed
  if (editName.value !== originalName.value) return true;
  
  // Check if any field value changed or if field modes changed (which affects saving)
  // Actually fieldModes is derived, but let's stick to fieldValues comparison
  const currentKeys = Object.keys(fieldValues.value);
  const originalKeys = Object.keys(originalValues.value);
  
  if (currentKeys.length !== originalKeys.length) return true;
  
  for (const key of currentKeys) {
    if (JSON.stringify(fieldValues.value[key]) !== JSON.stringify(originalValues.value[key])) {
      return true;
    }
  }
  
  return false;
});

// Initialize field state when node changes
watch(
  [() => props.node, () => props.isOpen],
  ([newNode, open]) => {
    if (open && newNode && newNode.data) {
      const config = newNode.data.config || {};
      const modes: Record<string, 'literal' | 'expression'> = {};
      const values: Record<string, unknown> = {};

      Object.entries(config).forEach(([key, value]) => {
        const isExpr = typeof value === 'string' && (value.includes('{{') || value.includes('{%'));
        modes[key] = isExpr ? 'expression' : 'literal';
        values[key] = value;
      });

      fieldModes.value = modes;
      fieldValues.value = values;
      editName.value = newNode.data.name || '';
      isEditingName.value = false;

      // Track original state
      originalValues.value = { ...values };
      originalName.value = editName.value;
      showCloseConfirmation.value = false;
    }
  },
  { immediate: true }
);

// Watch for changes and emit preview events
watchDebounced(
  fieldValues,
  newValues => {
    if (!canEdit.value) return;
    if (!props.isOpen || !props.node) return;

    Object.entries(newValues).forEach(([key, value]) => {
      if (fieldModes.value[key] === 'expression' && typeof value === 'string' && props.node) {
        emit('preview_expression', {
          step_id: props.node.id,
          field_key: key,
          expression: value,
        });
      }
    });
  },
  { debounce: 300, deep: true }
);

const closeModal = () => {
  if (hasUnsavedChanges.value) {
    showCloseConfirmation.value = true;
  } else {
    emit('close');
  }
};

const confirmClose = () => {
  showCloseConfirmation.value = false;
  emit('close');
};

const cancelClose = () => {
  showCloseConfirmation.value = false;
};

const saveConfig = () => {
  if (!canEdit.value) {
    closeModal();
    return;
  }
  emit('save', {
    id: props.node?.id,
    name: editName.value,
    config: { ...fieldValues.value },
  });
  
  // Update original state to match current before closing
  originalValues.value = { ...fieldValues.value };
  originalName.value = editName.value;
  
  emit('close');
};

const toggleMode = (field: string) => {
  if (!canEdit.value) return;
  fieldModes.value[field] = fieldModes.value[field] === 'literal' ? 'expression' : 'literal';
};

// Map schema types to input types
type FieldType = 'text' | 'number' | 'boolean' | 'textarea' | 'json';

const fields = computed(() => {
  if (!props.node || !props.node.data) return [];

  const schema = (props.stepType?.config_schema as ConfigSchema | undefined)?.properties || {};
  const config = props.node.data.config || {};

  // Combine schema-defined fields and existing config fields
  const allKeys = new Set([...Object.keys(schema), ...Object.keys(config)]);

  return Array.from(allKeys).map(key => {
    const schemaField: ConfigSchemaField = schema[key] ?? {};
    let type = inferType(config[key] ?? schemaField.default);

    if (schemaField.format === 'json') {
      type = 'json';
    } else if (schemaField.type === 'string' && schemaField.format === 'textarea') {
      type = 'textarea';
    }

    return {
      key,
      label: schemaField.title || key.replace(/_/g, ' ').replace(/\b\w/g, l => l.toUpperCase()),
      type,
    };
  });
});

const inferType = (val: unknown): FieldType => {
  if (typeof val === 'boolean') return 'boolean';
  if (typeof val === 'number') return 'number';
  if (typeof val === 'string' && val.length > 50) return 'textarea';
  return 'text';
};

const expandedSections = ref<Record<string, boolean>>({
  json: true,
  trigger: true,
  steps: true,
  variables: true,
});

const toggleSection = (id: string) => {
  expandedSections.value[id] = !expandedSections.value[id];
};

// All step executions for the current step (for multi-item fan-out steps)
const stepExecutionsForStep = computed(() => {
  if (!props.node || !props.stepExecutions) return [];
  return props.stepExecutions
    .filter(se => se.step_id === props.node?.id)
    .sort((a, b) => (a.item_index ?? -1) - (b.item_index ?? -1));
});

// Check if this is a multi-item step
const isMultiItemStep = computed(() => {
  const executions = stepExecutionsForStep.value;
  if (executions.length === 0) return false;
  const first = executions[0];
  return (first.items_total ?? 0) > 1 || executions.length > 1;
});

// Item stats for summary display
const itemStats = computed(() => {
  const executions = stepExecutionsForStep.value;
  if (executions.length === 0) return null;
  const first = executions[0];
  return {
    itemsTotal: first.items_total ?? executions.length,
    completed: executions.filter(e => e.status === 'completed').length,
    failed: executions.filter(e => e.status === 'failed').length,
    running: executions.filter(e => e.status === 'running').length,
    skipped: executions.filter(e => e.status === 'skipped').length,
  };
});

// Currently selected item index for drilldown (null = show summary)
const selectedItemIndex = ref<number | null>(null);

// Reset selected item when step changes
watch(
  () => props.node?.id,
  () => {
    selectedItemIndex.value = null;
  }
);

const activeStepExecution = computed(() => {
  const executions = stepExecutionsForStep.value;
  if (executions.length === 0) return null;

  // If multi-item and an item is selected, return that item's execution
  if (isMultiItemStep.value && selectedItemIndex.value !== null) {
    return executions.find(e => e.item_index === selectedItemIndex.value) || executions[0];
  }

  // Otherwise return the first (or only) execution
  return executions[0];
});

const pinnedOutputs = computed(() => props.editorState?.pinned_outputs ?? {});
const hasPinnedOutput = computed(() => {
  const stepId = props.node?.id;
  if (!stepId) return false;
  return Object.prototype.hasOwnProperty.call(pinnedOutputs.value, stepId);
});
const pinnedOutput = computed(() => {
  if (!props.node?.id || !hasPinnedOutput.value) return null;
  return pinnedOutputs.value[props.node.id];
});
const canPinOutput = computed(() => {
  const execution = activeStepExecution.value;
  return !!execution && execution.status === 'completed';
});
const pinButtonLabel = computed(() => (hasPinnedOutput.value ? 'Update Pin' : 'Pin Output'));

const pinOutput = () => {
  if (!canEdit.value) return;
  if (!props.node || !activeStepExecution.value || !canPinOutput.value) return;
  emit('pin_output', {
    step_id: props.node.id,
    output_data: activeStepExecution.value.output_data ?? null,
    item_index: activeStepExecution.value.item_index ?? null,
  });
};

const unpinOutput = () => {
  if (!canEdit.value) return;
  if (!props.node) return;
  emit('unpin_output', { step_id: props.node.id });
};

const toRecord = (value: unknown): Record<string, unknown> | null => {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  return value as Record<string, unknown>;
};

const evaluatedConfig = computed<Record<string, unknown>>(() => {
  const metadata = toRecord(activeStepExecution.value?.metadata);
  const evaluated = toRecord(metadata?.evaluated_config);
  return evaluated ?? {};
});

const isTriggerStep = computed(() => {
  return (
    props.stepType?.step_kind === 'trigger' || props.node?.data?.step_kind === 'trigger' || false
  );
});

const directUpstreamStepIds = computed(() => {
  if (!props.node) return [];
  return props.incomingStepIds?.[props.node.id] ?? [];
});

const inputIndexLabels = computed(() => {
  const upstreamIds = directUpstreamStepIds.value;
  return upstreamIds.map(stepId => props.stepNameById?.[stepId] || stepId);
});

const timestampFor = (value: unknown): number => {
  if (!value) return 0;
  if (value instanceof Date) return value.getTime();
  if (typeof value === 'number') return value;
  if (typeof value === 'string') {
    const parsed = Date.parse(value);
    return Number.isNaN(parsed) ? 0 : parsed;
  }
  return 0;
};

const executionTimestamp = (execution: StepExecution): number => {
  return Math.max(
    timestampFor(execution.completed_at),
    timestampFor(execution.started_at),
    timestampFor(execution.inserted_at)
  );
};

const pickLatestExecution = (executions: StepExecution[]): StepExecution | null => {
  if (executions.length === 0) return null;
  return executions.reduce((latest, current) => {
    if (!latest) return current;
    return executionTimestamp(current) >= executionTimestamp(latest) ? current : latest;
  }, null as StepExecution | null);
};

const resolveLatestExecution = (stepId: string, itemIndex: number | null): StepExecution | null => {
  const executions = props.stepExecutions?.filter(se => se.step_id === stepId) ?? [];
  if (executions.length === 0) return null;

  if (itemIndex !== null) {
    const matching = executions.filter(se => se.item_index === itemIndex);
    const latestMatching = pickLatestExecution(matching);
    if (latestMatching) return latestMatching;
  }

  const singleItemExecutions = executions.filter(se => se.item_index === null || se.item_index === undefined);
  return pickLatestExecution(singleItemExecutions.length > 0 ? singleItemExecutions : executions);
};

const currentInputState = computed(() => {
  const upstreamIds = directUpstreamStepIds.value;
  const itemIndex = selectedItemIndex.value;

  if (!props.node) {
    return { status: 'missing', reason: 'no_step', data: null };
  }

  if (upstreamIds.length === 0) {
    const triggerData = props.execution?.trigger?.data;
    if (isTriggerStep.value && triggerData !== undefined) {
      return { status: 'available', reason: null, data: unwrapData(triggerData) };
    }
    return { status: 'missing', reason: 'no_upstream', data: null };
  }

  const outputs: unknown[] = [];
  const missingStatuses: Array<StepExecutionStatus | string | undefined> = [];

  upstreamIds.forEach(stepId => {
    const latest = resolveLatestExecution(stepId, itemIndex ?? null);
    if (!latest) {
      missingStatuses.push('not_run');
      return;
    }

    if (latest.status === 'completed') {
      outputs.push(unwrapData(latest.output_data));
      return;
    }

    if (latest.status === 'skipped' || latest.status === 'cancelled') {
      outputs.push(null);
      return;
    }

    if (latest.status === 'failed') {
      missingStatuses.push(latest.status);
      return;
    }

    missingStatuses.push(latest.status);
  });

  if (missingStatuses.length > 0) {
    const reason = missingStatuses.includes('failed') ? 'failed' : 'not_run';
    return { status: 'missing', reason, data: null };
  }

  if (upstreamIds.length === 1) {
    return { status: 'available', reason: null, data: outputs[0] };
  }

  return { status: 'available', reason: null, data: outputs };
});

const currentInputEmptyState = computed(() => {
  const reason = currentInputState.value.reason;
  const hasSingleUpstream = directUpstreamStepIds.value.length === 1;
  const hasMultipleUpstream = directUpstreamStepIds.value.length > 1;
  
  const runHint = hasSingleUpstream
    ? 'Run the previous step to fetch the latest upstream output.'
    : 'Run to this step to compute the latest upstream outputs.';

  if (reason === 'failed') {
    return {
      title: 'Upstream step failed',
      description: `The last upstream run failed, so input data is unavailable. ${runHint}`,
    };
  }

  if (reason === 'no_upstream') {
    return {
      title: isTriggerStep.value ? 'Waiting for trigger data' : 'No upstream input',
      description: isTriggerStep.value
        ? 'This trigger has not fired yet. Run to this step to capture input data.'
        : 'This step has no upstream connection yet. Run to this step to generate input data.',
    };
  }

  // For 'not_run' reason - some inputs might have data but not all are available
  if (hasMultipleUpstream) {
    return {
      title: 'Incomplete input data',
      description: 'Some upstream steps have data, but all inputs must be available before we can display them. Run to this step to compute the latest upstream outputs.',
    };
  }

  return {
    title: 'No input data yet',
    description: runHint,
  };
});

const runInputLabel = computed(() => {
  return directUpstreamStepIds.value.length === 1 ? 'Run previous step' : 'Run to this step';
});

const runInput = () => {
  if (!canEdit.value) return;
  if (!props.node) return;
  emit('run_node', props.node.id);
};

const contextData = computed(() => {
  const upstreamIds = props.node ? props.upstreamStepIds?.[props.node.id] || [] : [];
  const metadata = toRecord(props.execution?.metadata);
  const extras = toRecord(metadata?.extras);

  const steps =
    props.stepExecutions?.reduce<Record<string, { json: unknown }>>((acc, se) => {
      // Only include if it's an upstream step
      if (!upstreamIds.includes(se.step_id)) return acc;

      const stepName = props.stepNameById?.[se.step_id];
      const key = stepName && stepName.length > 0 ? stepName : se.step_id;

      acc[key] = { json: unwrapData(se.output_data) };
      return acc;
    }, {}) ?? {};

  return {
    json: currentInputState.value.data,
    trigger: props.execution?.trigger?.data || {},
    variables: metadata?.variables ?? {},
    request: extras?.request ?? {},
    steps,
  };
});

const explorerData = computed(() => {
  const data = contextData.value;

  const wrapPrimitive = (val: unknown, key: string) => {
    if (val === null || val === undefined) return val;
    if (Array.isArray(val)) return val;
    if (typeof val === 'object') return val;
    return { [key]: val };
  };

  return [
    {
      id: 'json',
      label: 'Input Data',
      icon: ArrowRightOnRectangleIcon,
      data: wrapPrimitive(data.json, 'json'),
    },
    {
      id: 'trigger',
      label: 'Trigger Data',
      icon: BoltIcon,
      data: wrapPrimitive(data.trigger, 'trigger'),
    },
    { id: 'steps', label: 'Upstream Steps', icon: CpuChipIcon, data: data.steps },
    {
      id: 'variables',
      label: 'Workflow Variables',
      icon: VariableIcon,
      data: wrapPrimitive(data.variables, 'variables'),
    },
    {
      id: 'request',
      label: 'Request Metadata',
      icon: GlobeAltIcon,
      data: wrapPrimitive(data.request, 'request'),
    },
  ];
});

const previewKeyFor = (fieldKey: string) => (props.node ? `${props.node.id}:${fieldKey}` : '');

const hasPreviewFor = (fieldKey: string) => {
  const key = previewKeyFor(fieldKey);
  if (!key) return false;
  return Object.prototype.hasOwnProperty.call(props.expressionPreviews || {}, key);
};

const previewValueFor = (fieldKey: string) => {
  const key = previewKeyFor(fieldKey);
  if (!key) return undefined;
  return props.expressionPreviews?.[key];
};

// Webhook Logic
const webhookMode = ref<'test' | 'production'>('test');
const isWebhookTrigger = computed(() => {
  const typeId = props.node?.data?.type_id;
  return typeId === 'webhook_trigger' || typeId === 'webhook';
});

const webhookPath = computed(() => {
  if (!props.node) return '';
  const rawPath = fieldValues.value?.path || props.node.data?.config?.path;
  const path = typeof rawPath === 'string' ? rawPath.trim() : '';
  return path.length > 0 ? path : props.node.id;
});

const webhookMethod = computed(() => {
  const rawMethod = props.node?.data?.config?.http_method;
  if (typeof rawMethod === 'string' && rawMethod.trim().length > 0) {
    return rawMethod.trim().toUpperCase();
  }
  return 'POST';
});

const webhookTestState = computed(() => props.editorState?.webhook_test || null);
const isWebhookListening = computed(() => {
  if (!props.node || !webhookTestState.value) return false;
  if (webhookTestState.value.step_id) {
    return webhookTestState.value.step_id === props.node.id;
  }
  return webhookTestState.value.path === webhookPath.value;
});

const isWebhookListeningElsewhere = computed(() => {
  if (!props.node || !webhookTestState.value) return false;
  return webhookTestState.value.step_id
    ? webhookTestState.value.step_id !== props.node.id
    : webhookTestState.value.path !== webhookPath.value;
});

const webhookUrl = computed(() => {
  if (!props.node) return '';
  const path = webhookPath.value;
  const baseUrl = window.location.origin;

  if (webhookMode.value === 'test') {
    return `${baseUrl}/api/hook-test/${path}`; // Draft/Test URL
  } else {
    return `${baseUrl}/api/hooks/${path}`; // Production URL
  }
});

const copyWebhookUrl = () => {
  navigator.clipboard.writeText(webhookUrl.value);
  // detailed toast could go here
};
const slugify = (text: string) => {
  // Key-safe format: lowercase alphanumeric + underscores (matches backend to_step_id)
  return text
    .toLowerCase()
    .replace(/[^\w\s]/g, '')
    .replace(/[\s]+/g, '_')
    .replace(/_+/g, '_')
    .replace(/^_|_$/g, '');
};

const getExpressionFor = (sectionId: string, key?: string) => {
  if (key === sectionId && sectionId !== 'steps') return `{{ ${sectionId} }}`;

  const isNumeric = (val: string) => /^\d+$/.test(val);
  const formatKey = (k: string) => (isNumeric(k) ? `[${k}]` : `.${k}`);
  const path = key ? formatKey(key) : '';

  switch (sectionId) {
    case 'json':
      return `{{ json${path} }}`;
    case 'trigger':
      return `{{ trigger${path} }}`;
    case 'variables':
      return `{{ variables${path} }}`;
    case 'request':
      return `{{ request${path} }}`;
    case 'steps':
      if (!key) return `{{ steps }}`;
      // If we are referring to a step, use its slugified name
      // If it's the current node, we use the potentially updated editName
      const currentStepId = props.node?.id;
      const currentStepName = props.node?.data?.name || '';
      const isCurrentStep = key === currentStepId || key === currentStepName;
      const resolvedName = isCurrentStep ? editName.value : props.stepNameById?.[key];
      const stepName = resolvedName && resolvedName.length > 0 ? resolvedName : key;
      const stepKey = stepName && stepName.length > 0 ? slugify(stepName) : key;
      return `{{ steps["${stepKey}"].json }}`;
    default:
      return `{{ ${sectionId}${path} }}`;
  }
};

const copyExpression = (sectionId: string, key?: string) => {
  const expression = getExpressionFor(sectionId, key);
  navigator.clipboard.writeText(expression);
  // Could add toast notification here
};

const formatSectionKey = (sectionId: string, key: string) => {
  if (sectionId !== 'json') return key;
  if (!Array.isArray(currentInputState.value.data)) return key;
  if (directUpstreamStepIds.value.length <= 1) return key;

  const index = Number(key);
  if (Number.isNaN(index)) return key;

  const label = inputIndexLabels.value[index];
  return label ? `${key} - ${label}` : key;
};

const toggleWebhookListening = () => {
  if (!canEdit.value) return;
  if (!props.node || isWebhookListeningElsewhere.value) return;
  emit('toggle_webhook_test', {
    action: isWebhookListening.value ? 'stop' : 'start',
    step_id: props.node.id,
    path: webhookPath.value,
    method: webhookMethod.value,
  });
};
</script>

<template>
  <div
    v-if="isOpen"
    class="fixed inset-0 z-[1100] flex items-center justify-center bg-black/60 p-4 backdrop-blur-sm sm:p-6"
    @keydown.esc="closeModal"
  >
    <div
      class="bg-base-100 border-base-300 animate-in fade-in zoom-in flex h-[90vh] w-full max-w-7xl flex-col overflow-hidden rounded-3xl border shadow-2xl duration-300"
      @mousedown.stop
    >
      <!-- Header -->
      <div
        class="border-base-200 bg-base-200/40 flex items-center justify-between border-b px-6 py-4"
      >
        <div class="flex items-center gap-4">
          <div
            class="bg-primary/10 text-primary flex h-12 w-12 items-center justify-center rounded-2xl shadow-inner"
          >
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="h-6 w-6"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M20 7l-8-4-8 4m16 0l-8 4m8-4v10l-8 4m0-10L4 7m8 4v10M4 7v10l8 4"
              />
            </svg>
          </div>
          <div>
            <div class="flex items-center gap-2">
              <div v-if="isEditingName && canEdit" class="flex items-center gap-2">
                <input
                  v-model="editName"
                  type="text"
                  class="input input-sm input-primary bg-base-100 border-base-300 text-lg font-bold"
                  @keyup.enter="isEditingName = false"
                  @blur="isEditingName = false"
                  auto-focus
                />
              </div>
              <h2
                v-else
                class="text-base-content group/name flex items-center gap-2 text-lg leading-none font-bold"
              >
                {{ editName }}
                <button
                  v-if="canEdit"
                  class="btn btn-ghost btn-xs btn-circle opacity-0 transition-opacity group-hover/name:opacity-100"
                  @click="isEditingName = true"
                >
                  <PencilIcon class="text-base-content/40 size-3.5" />
                </button>
              </h2>
              <span class="badge badge-primary badge-sm font-mono opacity-80">{{
                node?.id.slice(0, 8)
              }}</span>
            </div>
            <p class="text-base-content/50 mt-1 flex items-center gap-1.5 text-xs font-medium">
              <span class="bg-success h-1.5 w-1.5 rounded-full"></span>
              {{ node?.data?.type_id }} Step
            </p>
          </div>
        </div>

        <div class="flex items-center gap-2">
          <div class="bg-base-300/50 flex rounded-xl p-1">
            <button
              v-for="tab in ['config', 'output', 'pinned'] as const"
              :key="tab"
              class="rounded-lg px-4 py-2 text-xs font-bold capitalize transition-all"
              :class="
                activeTab === tab
                  ? 'bg-base-100 text-primary shadow-sm'
                  : 'text-base-content/60 hover:text-base-content'
              "
              @click="activeTab = tab"
            >
              {{ tab === 'config' ? 'Parameters' : tab }}
            </button>
          </div>

          <button
            class="btn btn-ghost btn-sm btn-circle hover:bg-error/10 hover:text-error ml-4"
            @click="closeModal"
          >
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="h-5 w-5"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M6 18L18 6M6 6l12 12"
              />
            </svg>
          </button>
        </div>
      </div>

      <!-- Main content -->
      <div class="bg-base-200/20 flex flex-1 overflow-hidden">
        <!-- Variable Explorer (Left) -->
        <div class="border-base-200 bg-base-100/50 flex w-80 flex-col overflow-hidden border-r">
          <div class="border-base-200 bg-base-200/10 border-b p-4">
            <div class="relative">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="text-base-content/40 absolute top-1/2 left-3 h-4 w-4 -translate-y-1/2"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M21 21l-6-6m2-5a7 7 0 11-14 0 7 7 0 0114 0z"
                />
              </svg>
              <input
                v-model="searchQuery"
                type="text"
                placeholder="Search variables..."
                class="input input-sm input-bordered bg-base-100 border-base-300 focus:border-primary w-full pl-9 text-xs font-medium"
              />
            </div>
          </div>
          <div class="custom-scrollbar flex-1 space-y-1 overflow-y-auto p-2">
            <div v-for="section in explorerData" :key="section.id" class="overflow-hidden">
              <button
                class="hover:bg-primary/5 group flex w-full items-center justify-between rounded-xl p-2 text-xs font-bold transition-all"
                :class="
                  expandedSections[section.id]
                    ? 'text-primary bg-primary/5'
                    : 'text-base-content/60'
                "
                @click="toggleSection(section.id)"
              >
                <div class="flex items-center gap-2">
                  <span class="opacity-70 group-hover:opacity-100">
                    <component :is="section.icon" class="h-4 w-4" />
                  </span>
                  {{ section.label }}
                </div>
                <svg
                  :class="{ 'rotate-90': expandedSections[section.id] }"
                  class="h-3 w-3 opacity-40 transition-transform"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                >
                  <path d="M9 5l7 7-7 7" stroke-width="2" />
                </svg>
              </button>
              <div
                v-if="expandedSections[section.id]"
                class="border-base-200 mt-1 ml-4 space-y-1 border-l py-1 pl-2 text-wrap"
              >
                <template v-if="section.id === 'json' && currentInputState.status !== 'available'">
                  <div class="bg-base-300/20 space-y-2 rounded-xl p-3">
                    <div class="text-base-content text-[11px] font-semibold">
                      {{ currentInputEmptyState.title }}
                    </div>
                    <p class="text-base-content/60 text-[10px] leading-relaxed">
                      {{ currentInputEmptyState.description }}
                    </p>
                    <button
                      class="btn btn-xs btn-primary w-full"
                      :disabled="!canEdit"
                      @click.stop="runInput"
                    >
                      {{ runInputLabel }}
                    </button>
                  </div>
                </template>
                <template
                  v-else-if="
                    section.data &&
                    typeof section.data === 'object' &&
                    Object.keys(section.data).length > 0
                  "
                >
                  <div
                    v-for="(val, key) in section.data"
                    :key="key"
                    class="hover:bg-base-200 group cursor-pointer rounded-lg p-1.5 transition-all"
                  >
                    <div class="flex items-center justify-between">
                      <span class="text-base-content font-mono text-[11px]">{{
                        formatSectionKey(section.id, String(key))
                      }}</span>
                      <button
                        @click.stop="copyExpression(section.id, String(key))"
                        class="btn btn-xs btn-ghost btn-square h-4 w-4 opacity-0 transition-opacity group-hover:opacity-100"
                        :title="'Copy expression: ' + getExpressionFor(section.id, String(key))"
                      >
                        <svg
                          xmlns="http://www.w3.org/2000/svg"
                          class="h-3 w-3"
                          fill="none"
                          viewBox="0 0 24 24"
                          stroke="currentColor"
                        >
                          <path
                            stroke-linecap="round"
                            stroke-linejoin="round"
                            stroke-width="2"
                            d="M8 5H6a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2v-1M8 5a2 2 0 002 2h2a2 2 0 002-2M8 5a2 2 0 002-2M8 5a2 2 0 012-2h2a2 2 0 012 2m0 0h2a2 2 0 012 2v3m2 4H10m0 0l3-3m-3 3l3 3"
                          />
                        </svg>
                      </button>
                    </div>
                    <div class="text-base-content/40 mt-0.5 truncate text-[10px]">
                      {{ JSON.stringify(val) }}
                    </div>
                  </div>
                </template>
                <div
                  v-else-if="section.data !== undefined && section.data !== null"
                  class="bg-base-300/10 group rounded-lg p-1.5"
                >
                  <div class="flex items-center justify-between gap-2">
                    <div class="text-base-content/60 flex-1 truncate font-mono text-[10px]">
                      {{ formatDataForDisplay(section.data) }}
                    </div>
                    <button
                      @click.stop="copyExpression(section.id)"
                      class="btn btn-xs btn-ghost btn-square h-4 w-4 opacity-0 transition-opacity group-hover:opacity-100"
                      :title="'Copy expression: ' + getExpressionFor(section.id)"
                    >
                      <svg
                        xmlns="http://www.w3.org/2000/svg"
                        class="h-3 w-3"
                        fill="none"
                        viewBox="0 0 24 24"
                        stroke="currentColor"
                      >
                        <path
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          stroke-width="2"
                          d="M8 5H6a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2v-1M8 5a2 2 0 002 2h2a2 2 0 002-2M8 5a2 2 0 002-2M8 5a2 2 0 012-2h2a2 2 0 012 2m0 0h2a2 2 0 012 2v3m2 4H10m0 0l3-3m-3 3l3 3"
                        />
                      </svg>
                    </button>
                  </div>
                </div>
                <div v-else class="text-base-content/40 p-2 text-[10px] italic">
                  No variables available
                </div>
              </div>
            </div>
          </div>
          <div class="border-base-200 bg-base-200/5 border-t p-4">
            <div class="text-base-content/40 mb-2 text-[10px] font-bold tracking-wider uppercase">
              Expression Tip
            </div>
            <p class="text-base-content/60 text-[11px] leading-relaxed">
              Click any variable to copy its Liquid expression to your clipboard.
            </p>
          </div>
        </div>

        <!-- Tab Content area (Config / Output) -->
        <div class="custom-scrollbar flex-1 overflow-y-auto p-8">
          <div v-if="activeTab === 'config'" class="mx-auto max-w-3xl space-y-10 pb-20">
            <div class="space-y-1">
              <h3 class="text-base-content text-lg font-semibold tracking-tight">
                {{ canEdit ? 'Step Configuration' : 'Step Inspector' }}
              </h3>
              <p class="text-base-content/50 text-xs font-medium">
                {{
                  canEdit
                    ? 'Configure the parameters for this operation.'
                    : 'Review configuration and runtime details for this step.'
                }}
              </p>
            </div>

            <!-- Webhook Specific UI -->
            <div
              v-if="isWebhookTrigger"
              class="bg-base-100 border-base-300 space-y-4 rounded-2xl border p-5 shadow-sm"
            >
              <div class="flex items-center justify-between">
                <h4 class="text-base-content flex items-center gap-2 text-sm font-bold">
                  <svg
                    xmlns="http://www.w3.org/2000/svg"
                    class="text-primary h-4 w-4"
                    fill="none"
                    viewBox="0 0 24 24"
                    stroke="currentColor"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M13.828 10.172a4 4 0 00-5.656 0l-4 4a4 4 0 105.656 5.656l1.102-1.101m-.758-4.899a4 4 0 005.656 0l4-4a4 4 0 00-5.656-5.656l-1.1 1.1"
                    />
                  </svg>
                  Webhook URLs
                </h4>
                <div class="join bg-base-200/50 rounded-lg p-1">
                  <button
                    class="join-item btn btn-xs px-3"
                    :class="webhookMode === 'test' ? 'btn-primary' : 'btn-ghost'"
                    @click="webhookMode = 'test'"
                  >
                    Test URL
                  </button>
                  <button
                    class="join-item btn btn-xs px-3"
                    :class="webhookMode === 'production' ? 'btn-neutral' : 'btn-ghost'"
                    @click="webhookMode = 'production'"
                  >
                    Production URL
                  </button>
                </div>
              </div>

              <div class="relative">
                <div class="pointer-events-none absolute inset-y-0 left-0 flex items-center pl-3">
                  <span
                    class="badge badge-sm font-mono text-[10px]"
                    :class="webhookMode === 'test' ? 'badge-primary' : 'badge-neutral'"
                    >{{ webhookMethod }}</span
                  >
                </div>
                <input
                  type="text"
                  readonly
                  :value="webhookUrl"
                  class="input input-sm bg-base-200/30 border-base-300 text-base-content/70 selection:bg-primary/20 w-full pl-16 font-mono text-xs"
                  @click="($event.target as HTMLInputElement).select()"
                />
                <div class="absolute inset-y-0 right-0 flex items-center pr-1">
                  <button class="btn btn-xs btn-ghost btn-square" @click="copyWebhookUrl">
                    <svg
                      xmlns="http://www.w3.org/2000/svg"
                      class="h-4 w-4 opacity-50"
                      fill="none"
                      viewBox="0 0 24 24"
                      stroke="currentColor"
                    >
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2"
                        d="M8 5H6a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2v-1M8 5a2 2 0 002 2h2a2 2 0 002-2M8 5a2 2 0 002-2M8 5a2 2 0 012-2h2a2 2 0 012 2m0 0h2a2 2 0 012 2v3m2 4H10m0 0l3-3m-3 3l3 3"
                      />
                    </svg>
                  </button>
                </div>
              </div>

              <div v-if="canEdit && webhookMode === 'test'" class="space-y-3 pt-2">
                <div class="flex items-center gap-4">
                  <button
                    class="btn btn-sm w-full gap-2 shadow-lg"
                    :class="
                      isWebhookListening
                        ? 'btn-error shadow-error/20'
                        : 'btn-primary shadow-primary/20'
                    "
                    :disabled="isWebhookListeningElsewhere"
                    @click="toggleWebhookListening"
                  >
                    <svg
                      xmlns="http://www.w3.org/2000/svg"
                      class="h-4 w-4"
                      :class="isWebhookListening ? '' : 'animate-pulse'"
                      fill="none"
                      viewBox="0 0 24 24"
                      stroke="currentColor"
                    >
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2"
                        d="M5.636 18.364a9 9 0 010-12.728m12.728 0a9 9 0 010 12.728m-9.9-2.829a5 5 0 010-7.07m7.072 0a5 5 0 010 7.07M13 12a1 1 0 11-2 0 1 1 0 012 0z"
                      />
                    </svg>
                    {{ isWebhookListening ? 'Stop listening' : 'Listen for test event' }}
                  </button>
                  <p class="text-base-content/50 flex-1 text-[10px] leading-tight">
                    {{
                      isWebhookListening
                        ? 'Listening for a test request. Send it to the URL to capture payloads.'
                        : 'Enable a temporary test listener while editing this draft.'
                    }}
                  </p>
                </div>

                <div
                  v-if="isWebhookListening"
                  class="border-primary/20 bg-primary/5 text-base-content/70 rounded-xl border px-4 py-3 text-[11px]"
                >
                  Listening for test event. Send a {{ webhookMethod }} request to the Test URL.
                </div>
                <div
                  v-else-if="isWebhookListeningElsewhere"
                  class="border-warning/20 bg-warning/5 text-base-content/70 rounded-xl border px-4 py-3 text-[11px]"
                >
                  Another webhook trigger is already listening. Stop it to enable this one.
                </div>
              </div>
            </div>

            <div class="space-y-6">
              <div v-for="field in fields" :key="field.key" class="group relative">
                <div
                  class="rounded-2xl border transition-all duration-300"
                  :class="
                    fieldModes[field.key] === 'literal'
                      ? 'border-base-300 bg-base-100 shadow-sm'
                      : 'border-secondary/20 bg-secondary/[0.02] shadow-inner'
                  "
                >
                  <div
                    class="border-base-200/50 flex items-center justify-between border-b px-5 py-3"
                  >
                    <label class="text-base-content block text-sm font-medium tracking-tight">{{
                      field.label
                    }}</label>

                    <div v-if="canEdit" class="join">
                      <button
                        class="join-item btn btn-xs capitalize"
                        :class="fieldModes[field.key] === 'literal' ? 'btn-primary' : 'btn-ghost'"
                        @click="toggleMode(field.key)"
                      >
                        Fixed
                      </button>
                      <button
                        class="join-item btn btn-xs capitalize"
                        :class="
                          fieldModes[field.key] === 'expression' ? 'btn-secondary' : 'btn-ghost'
                        "
                        @click="toggleMode(field.key)"
                      >
                        Expression
                      </button>
                    </div>
                    <div
                      v-else
                      class="text-base-content/50 rounded-full border border-base-200 px-3 py-1 text-[10px] font-semibold uppercase tracking-wide"
                    >
                      {{ fieldModes[field.key] === 'expression' ? 'Expression' : 'Fixed' }}
                    </div>
                  </div>

                  <div class="p-5">
                    <template v-if="fieldModes[field.key] === 'literal'">
                      <textarea
                        v-if="field.type === 'textarea' || field.type === 'json'"
                        v-model="
                          fieldValues[field.key] as
                            | string
                            | number
                            | readonly string[]
                            | null
                            | undefined
                        "
                        :readonly="!canEdit"
                        class="textarea textarea-bordered bg-base-200/10 border-base-300 focus:border-primary min-h-[100px] w-full rounded-xl font-mono text-xs"
                        :placeholder="
                          field.type === 'json'
                            ? '{ \n  &quot;key&quot;: &quot;value&quot; \n}'
                            : ''
                        "
                      ></textarea>
                      <input
                        v-else
                        v-model="
                          fieldValues[field.key] as
                            | string
                            | number
                            | readonly string[]
                            | null
                            | undefined
                        "
                        :type="field.type === 'number' ? 'number' : 'text'"
                        :readonly="!canEdit"
                        class="input input-md bg-base-200/20 border-base-300 focus:border-primary w-full rounded-xl text-sm font-medium"
                      />
                    </template>
                    <template v-else>
                      <div class="space-y-3">
                        <textarea
                          v-model="
                            fieldValues[field.key] as
                              | string
                              | number
                              | readonly string[]
                              | null
                              | undefined
                          "
                          :readonly="!canEdit"
                          class="textarea bg-base-100 border-secondary/10 focus:border-secondary/40 focus:ring-secondary/5 min-h-[80px] w-full rounded-xl border-2 font-mono text-[13px] focus:ring-4"
                          placeholder="{{ steps.PreviousStep.json.field }}"
                        ></textarea>

                        <!-- Live Preview -->
                        <div
                          v-if="hasPreviewFor(field.key)"
                          class="border-base-200/60 bg-base-200/20 overflow-hidden rounded-xl border"
                        >
                          <div
                            class="border-base-200/40 bg-base-200/30 flex items-center justify-between border-b px-4 py-1.5"
                          >
                            <span
                              class="text-base-content/30 text-[9px] font-bold tracking-widest uppercase"
                              >Live Preview</span
                            >
                            <span class="text-success text-[9px] font-bold uppercase">Draft</span>
                          </div>
                          <div class="text-base-content/70 p-3 font-mono text-[11px]">
                            <template
                              v-if="
                                typeof previewValueFor(field.key) === 'object' &&
                                previewValueFor(field.key) !== null
                              "
                            >
                              <ExpressionPreviewError
                                :error="previewValueFor(field.key) as ErrorPayload"
                              />
                            </template>
                            <template v-else>
                              {{
                                previewValueFor(field.key) || 'Run a test to see preview results'
                              }}
                            </template>
                          </div>
                        </div>

                        <!-- Result from execution -->
                        <div
                          v-else-if="evaluatedConfig[field.key] !== undefined"
                          class="border-secondary/20 bg-secondary/[0.03] overflow-hidden rounded-xl border"
                        >
                          <div
                            class="border-secondary/10 bg-secondary/5 flex items-center justify-between border-b px-4 py-1.5"
                          >
                            <span
                              class="text-secondary/60 text-[9px] font-bold tracking-widest uppercase"
                              >Resolved Result</span
                            >
                            <span class="text-secondary text-[9px] font-bold uppercase">Value</span>
                          </div>
                          <div class="text-base-content/70 p-3 font-mono text-[11px]">
                            {{ evaluatedConfig[field.key] }}
                          </div>
                        </div>

                        <!-- Live Preview (Mock or fallback) -->
                        <div
                          v-else
                          class="border-base-200/60 bg-base-200/20 overflow-hidden rounded-xl border"
                        >
                          <div
                            class="border-base-200/40 bg-base-200/30 flex items-center justify-between border-b px-4 py-1.5"
                          >
                            <span
                              class="text-base-content/30 text-[9px] font-bold tracking-widest uppercase"
                              >Live Preview</span
                            >
                            <span class="text-success text-[9px] font-bold uppercase">Draft</span>
                          </div>
                          <div class="text-base-content/70 p-3 font-mono text-[11px]">
                            {{ 'Run a test to see preview results' }}
                          </div>
                        </div>
                      </div>
                    </template>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <div
            v-else-if="activeTab === 'output'"
            class="custom-scrollbar mx-auto h-full max-w-4xl space-y-8 p-4"
          >
            <div v-if="activeStepExecution" class="space-y-8 pb-20">
              <!-- Multi-Item Summary Bar -->
              <section v-if="isMultiItemStep && itemStats" class="bg-base-200/50 rounded-2xl p-4">
                <div class="flex items-center justify-between">
                  <div class="flex items-center gap-4">
                    <span class="text-base-content/60 text-sm font-medium">
                      {{ itemStats.itemsTotal }} items processed
                    </span>
                    <div class="flex items-center gap-2 text-xs">
                      <span
                        v-if="itemStats.completed > 0"
                        class="text-success flex items-center gap-1"
                      >
                        <span class="bg-success inline-block size-2 rounded-full"></span>
                        {{ itemStats.completed }} completed
                      </span>
                      <span v-if="itemStats.failed > 0" class="text-error flex items-center gap-1">
                        <span class="bg-error inline-block size-2 rounded-full"></span>
                        {{ itemStats.failed }} failed
                      </span>
                      <span v-if="itemStats.running > 0" class="text-info flex items-center gap-1">
                        <span class="bg-info inline-block size-2 rounded-full"></span>
                        {{ itemStats.running }} running
                      </span>
                    </div>
                  </div>
                  <button
                    v-if="selectedItemIndex !== null"
                    @click="selectedItemIndex = null"
                    class="btn btn-xs btn-ghost"
                  >
                    Show All
                  </button>
                </div>

                <!-- Item List -->
                <div class="mt-4 flex flex-wrap gap-2">
                  <button
                    v-for="se in stepExecutionsForStep"
                    :key="se.id"
                    @click="selectedItemIndex = se.item_index ?? 0"
                    :class="[
                      'btn btn-xs gap-1',
                      selectedItemIndex === se.item_index ? 'btn-primary' : 'btn-ghost',
                      se.status === 'failed' ? 'border-error/50' : '',
                      se.status === 'completed' ? 'border-success/30' : '',
                    ]"
                  >
                    <span
                      :class="[
                        'inline-block size-2 rounded-full',
                        se.status === 'completed' ? 'bg-success' : '',
                        se.status === 'failed' ? 'bg-error' : '',
                        se.status === 'running' ? 'bg-info animate-pulse' : '',
                        se.status === 'skipped' ? 'bg-base-content/30' : '',
                      ]"
                    ></span>
                    #{{ (se.item_index ?? 0) + 1 }}
                  </button>
                </div>
              </section>

              <!-- Item Header (when viewing specific item) -->
              <div
                v-if="isMultiItemStep && selectedItemIndex !== null"
                class="flex items-center gap-2 text-sm"
              >
                <span class="text-base-content/60">Viewing item</span>
                <span class="font-bold">#{{ selectedItemIndex + 1 }}</span>
                <span class="text-base-content/40">of {{ itemStats?.itemsTotal }}</span>
                <span
                  :class="[
                    'badge badge-sm',
                    activeStepExecution.status === 'completed' ? 'badge-success' : '',
                    activeStepExecution.status === 'failed' ? 'badge-error' : '',
                    activeStepExecution.status === 'running' ? 'badge-info' : '',
                  ]"
                >
                  {{ activeStepExecution.status }}
                </span>
              </div>

              <section>
                <div class="mb-3 flex items-center justify-between">
                  <h4 class="text-base-content/40 text-xs font-bold tracking-widest uppercase">
                    Input Data
                  </h4>
                  <button
                    @click.stop="copyExpression('json')"
                    class="btn btn-xs btn-ghost gap-1.5 text-[10px] capitalize opacity-60 hover:opacity-100"
                  >
                    <svg
                      xmlns="http://www.w3.org/2000/svg"
                      class="h-3 w-3"
                      fill="none"
                      viewBox="0 0 24 24"
                      stroke="currentColor"
                    >
                      <path
                        stroke-linecap="round"
                        stroke-linejoin="round"
                        stroke-width="2"
                        d="M8 5H6a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2v-1M8 5a2 2 0 002 2h2a2 2 0 002-2M8 5a2 2 0 002-2M8 5a2 2 0 012-2h2a2 2 0 012 2m0 0h2a2 2 0 012 2v3m2 4H10m0 0l3-3m-3 3l3 3"
                      />
                    </svg>
                    Copy Expression
                  </button>
                </div>
                <div
                  class="bg-base-300/30 overflow-x-auto rounded-2xl p-4 font-mono text-xs whitespace-pre"
                >
                  {{ formatDataForDisplay(activeStepExecution.input_data) }}
                </div>
              </section>

              <section>
                <div class="mb-3 flex items-center justify-between">
                  <h4 class="text-base-content/40 text-xs font-bold tracking-widest uppercase">
                    Output Data
                  </h4>
                  <div class="flex items-center gap-2">
                    <button
                      v-if="canEdit"
                      @click.stop="pinOutput"
                      class="btn btn-xs btn-ghost gap-1.5 text-[10px] capitalize opacity-60 hover:opacity-100"
                      :disabled="!canPinOutput"
                      :title="
                        canPinOutput
                          ? pinButtonLabel
                          : 'Run the workflow to capture output before pinning'
                      "
                    >
                      <BookmarkIcon class="h-3 w-3" />
                      {{ pinButtonLabel }}
                    </button>
                    <button
                      @click.stop="copyExpression('steps', node?.id)"
                      class="btn btn-xs btn-ghost gap-1.5 text-[10px] capitalize opacity-60 hover:opacity-100"
                    >
                      <svg
                        xmlns="http://www.w3.org/2000/svg"
                        class="h-3 w-3"
                        fill="none"
                        viewBox="0 0 24 24"
                        stroke="currentColor"
                      >
                        <path
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          stroke-width="2"
                          d="M8 5H6a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2v-1M8 5a2 2 0 002 2h2a2 2 0 002-2M8 5a2 2 0 002-2M8 5a2 2 0 012-2h2a2 2 0 012 2m0 0h2a2 2 0 012 2v3m2 4H10m0 0l3-3m-3 3l3 3"
                        />
                      </svg>
                      Copy Expression
                    </button>
                    <span v-if="hasPinnedOutput" class="badge badge-secondary badge-sm"
                      >Pinned</span
                    >
                    <span
                      v-if="activeStepExecution.status === 'completed'"
                      class="badge badge-success badge-sm"
                      >Success</span
                    >
                  </div>
                </div>
                <div
                  class="bg-base-300/30 border-success/10 overflow-x-auto rounded-2xl border-2 p-4 font-mono text-xs whitespace-pre"
                >
                  {{ formatDataForDisplay(activeStepExecution.output_data) }}
                </div>
              </section>

              <section v-if="activeStepExecution.error">
                <h4 class="text-error/60 mb-3 text-xs font-bold tracking-widest uppercase">
                  Error
                </h4>
                <div
                  class="bg-error/5 border-error/20 text-error rounded-2xl border p-4 font-mono text-xs"
                >
                  {{ activeStepExecution.error }}
                </div>
              </section>
            </div>

            <div v-else class="flex h-full flex-col items-center justify-center opacity-40">
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="mb-4 h-16 w-16"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="1.5"
                  d="M13 10V3L4 14h7v7l9-11h-7z"
                />
              </svg>
              <p class="text-sm font-bold">No execution data available</p>
              <p class="text-xs">Run the workflow to see inputs and outputs</p>
            </div>
          </div>

          <div v-else class="custom-scrollbar mx-auto h-full max-w-4xl space-y-8 p-4">
            <div v-if="hasPinnedOutput" class="space-y-6 pb-20">
              <section class="space-y-3">
                <div class="flex items-start justify-between gap-4">
                  <div>
                    <h4 class="text-base-content/40 text-xs font-bold tracking-widest uppercase">
                      Pinned Output
                    </h4>
                    <p class="text-base-content/50 mt-1 text-xs font-medium">
                      Pinned outputs are reused when running previews.
                    </p>
                  </div>
                  <div class="flex items-center gap-2">
                    <button
                      v-if="canEdit"
                      @click.stop="pinOutput"
                      class="btn btn-xs btn-ghost gap-1.5 text-[10px] capitalize opacity-60 hover:opacity-100"
                      :disabled="!canPinOutput"
                      :title="
                        canPinOutput
                          ? pinButtonLabel
                          : 'Run the workflow to capture output before pinning'
                      "
                    >
                      <BookmarkIcon class="h-3 w-3" />
                      {{ pinButtonLabel }}
                    </button>
                    <button
                      v-if="canEdit"
                      class="btn btn-xs btn-ghost text-error/80 hover:text-error"
                      @click.stop="unpinOutput"
                    >
                      Unpin
                    </button>
                  </div>
                </div>
                <div
                  class="bg-base-300/30 overflow-x-auto rounded-2xl p-4 font-mono text-xs whitespace-pre"
                >
                  {{ formatDataForDisplay(pinnedOutput) }}
                </div>
              </section>
            </div>

            <div
              v-else
              class="flex h-full flex-col items-center justify-center gap-3 text-center opacity-40"
            >
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-16 w-16"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="1.5"
                  d="M5 5a2 2 0 012-2h10a2 2 0 012 2v16l-7-3.5L5 21V5z"
                />
              </svg>
              <div>
                <p class="text-sm font-bold">No pinned output</p>
                <p class="text-xs">Pin an output to reuse it during previews.</p>
              </div>
              <button
                v-if="canEdit && canPinOutput"
                class="btn btn-xs btn-primary"
                @click.stop="pinOutput"
              >
                Pin latest output
              </button>
            </div>
          </div>
        </div>
      </div>

      <!-- Footer -->
      <div class="border-base-200 bg-base-100 flex items-center justify-end border-t px-8 py-5">
        <div class="flex items-center gap-4">
          <template v-if="canEdit">
            <button class="btn btn-ghost btn-sm text-base-content/60 font-bold" @click="closeModal">
              Discard Changes
            </button>
            <button
              class="btn btn-primary shadow-primary/20 rounded-xl px-8 font-bold shadow-lg"
              @click="saveConfig"
            >
              Save Configuration
            </button>
          </template>
          <template v-else>
            <button class="btn btn-ghost btn-sm text-base-content/60 font-bold" @click="closeModal">
              Close
            </button>
          </template>
        </div>
      </div>

      <!-- Unsaved Changes Confirmation Overlay -->
      <div
        v-if="showCloseConfirmation"
        class="absolute inset-0 z-[1200] flex items-center justify-center bg-black/40 backdrop-blur-md animate-in fade-in duration-200"
      >
        <div
          class="bg-base-100 border-base-300 w-full max-w-md scale-100 transform rounded-3xl border p-8 shadow-2xl animate-in zoom-in duration-200"
        >
          <div class="mb-6 flex flex-col items-center text-center">
            <div
              class="bg-warning/10 text-warning mb-4 flex h-16 w-16 items-center justify-center rounded-2xl"
            >
              <svg
                xmlns="http://www.w3.org/2000/svg"
                class="h-8 w-8"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M12 9v2m0 4h.01m-6.938 4h13.856c1.54 0 2.502-1.667 1.732-3L13.732 4c-.77-1.333-2.694-1.333-3.464 0L3.34 16c-.77 1.333.192 3 1.732 3z"
                />
              </svg>
            </div>
            <h3 class="text-xl font-bold">Unsaved Changes</h3>
            <p class="text-base-content/60 mt-2 text-sm">
              You have unsaved changes in this step configuration. Are you sure you want to discard
              them?
            </p>
          </div>
          <div class="grid grid-cols-2 gap-3">
            <button
              class="btn btn-ghost border-base-300 hover:bg-base-200 rounded-xl font-bold"
              @click="cancelClose"
            >
              Keep Editing
            </button>
            <button class="btn btn-error rounded-xl font-bold shadow-lg shadow-error/20" @click="confirmClose">
              Discard Changes
            </button>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<style scoped>
.custom-scrollbar::-webkit-scrollbar {
  width: 6px;
}

.custom-scrollbar::-webkit-scrollbar-thumb {
  background: color-mix(in oklch, var(--color-base-content) 10%, transparent);
  border-radius: 10px;
}
</style>
