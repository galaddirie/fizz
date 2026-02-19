<script setup lang="ts">
import { ref, computed, watch } from 'vue';
import type {
  Execution,
  StepExecution,
  TraceEntry,
  ExecutionStatus,
  StepExecutionStatus,
} from '@/types/workflow';
import {
  ChevronUpIcon,
  ExclamationCircleIcon,
  ClockIcon,
  StopIcon,
} from '@heroicons/vue/24/outline';

// Props from LiveView
interface Props {
  execution?: Execution | null;
  stepExecutions?: StepExecution[];
  isExpanded?: boolean;
  stepNameById?: Record<string, string>;
  selectedStepId?: string | null;
}

const props = withDefaults(defineProps<Props>(), {
  execution: null,
  stepExecutions: () => [],
  isExpanded: true,
  stepNameById: () => ({}),
  selectedStepId: null,
});

const emit = defineEmits<{
  (e: 'toggle'): void;
  (e: 'close'): void;
  (e: 'selectStep', stepId: string): void;
  (e: 'runTest'): void;
  (e: 'cancel'): void;
}>();

const activeTab = ref<'input' | 'output'>('input');
const localSelectedStepId = ref<string | null>(null);
const expandedMultiItemSteps = ref<Set<string>>(new Set());
const activeIterationId = ref<string | null>(null);

// Mock data when no props (for development)
const mockTraces: TraceEntry[] = [
  {
    id: '1',
    step_id: 'trigger_1',
    step_name: 'Manual Trigger',
    status: 'completed',
    duration_us: 120,
    timestamp: '16:15:01.234',
  },
  {
    id: '2',
    step_id: 'step_http',
    step_name: 'Fetch User Data',
    status: 'completed',
    duration_us: 245000,
    timestamp: '16:15:02.456',
  },
  {
    id: '3',
    step_id: 'step_condition',
    step_name: 'Check Status',
    status: 'completed',
    duration_us: 85,
    timestamp: '16:15:02.789',
  },
  {
    id: '4',
    step_id: 'step_transform',
    step_name: 'Format Response',
    status: 'running',
    timestamp: '16:15:03.012',
  },
];

const selectedTraceEntry = computed(() => {
  if (!localSelectedStepId.value) return null;
  return traces.value.find(trace => trace.step_id === localSelectedStepId.value) || null;
});

const selectedStepExecution = computed(() => {
  if (!localSelectedStepId.value) return null;
  return props.stepExecutions.find(se => se.step_id === localSelectedStepId.value) || null;
});

// Watch for external selection changes and sync to local state
watch(
  () => props.selectedStepId,
  newSelectedStepId => {
    localSelectedStepId.value = newSelectedStepId ?? null;
  },
  { immediate: true }
);

const formatTraceTimestamp = (execution: StepExecution): string => {
  if (execution.started_at) return new Date(execution.started_at).toLocaleTimeString();
  if (execution.completed_at) return new Date(execution.completed_at).toLocaleTimeString();
  return '';
};

// Computed traces from props or mock
const traces = computed<TraceEntry[]>(() => {
  if (props.stepExecutions.length > 0) {
    const executionsByStep = new Map<string, StepExecution[]>();
    for (const se of props.stepExecutions) {
      if (!executionsByStep.has(se.step_id)) executionsByStep.set(se.step_id, []);
      executionsByStep.get(se.step_id)!.push(se);
    }

    const result: TraceEntry[] = [];

    for (const [stepId, executions] of executionsByStep.entries()) {
      const firstExecution = executions[0];
      const baseName = props.stepNameById?.[stepId] || stepId;

      const isMultiItem = firstExecution.items_total && firstExecution.items_total > 1;

      if (isMultiItem) {
        const completedCount = executions.filter(se => se.status === 'completed').length;
        const failedCount = executions.filter(se => se.status === 'failed').length;
        const runningCount = executions.filter(se => se.status === 'running').length;

        let overallStatus: StepExecutionStatus = 'pending';
        if (runningCount > 0) overallStatus = 'running';
        else if (failedCount > 0) overallStatus = 'failed';
        else if (completedCount === executions.length) overallStatus = 'completed';

        const totalDuration = executions.reduce((sum, se) => sum + (se.duration_us || 0), 0);

        const earliestExecution = executions.reduce((earliest, se) => {
          if (!earliest) return se;
          const earliestTime = earliest.started_at || earliest.completed_at || earliest.inserted_at;
          const currentTime = se.started_at || se.completed_at || se.inserted_at;
          return currentTime < earliestTime ? se : earliest;
        });

        result.push({
          id: `group-${stepId}`,
          step_id: stepId,
          step_name: baseName,
          step_type_id: firstExecution.step_type_id,
          status: overallStatus,
          duration_us: totalDuration,
          timestamp: formatTraceTimestamp(earliestExecution),
          item_index: null,
          items_total: firstExecution.items_total,
          isMultiItem: true,
          iterations: executions
            .map(se => ({
              id: se.id,
              status: se.status,
              duration_us: se.duration_us,
              timestamp: formatTraceTimestamp(se),
              input_data: se.input_data,
              output_data: se.output_data,
              error: se.error,
              item_index: se.item_index,
            }))
            .sort((a, b) => (a.item_index || 0) - (b.item_index || 0)),
        });
      } else {
        const se = firstExecution;
        result.push({
          id: se.id,
          step_id: se.step_id,
          step_name: baseName,
          step_type_id: se.step_type_id,
          status: se.status,
          duration_us: se.duration_us,
          timestamp: formatTraceTimestamp(se),
          error: se.error ? JSON.stringify(se.error) : undefined,
          item_index: se.item_index,
          items_total: se.items_total,
          isMultiItem: false,
          input_data: se.input_data,
          output_data: se.output_data,
        });
      }
    }

    return result.sort((a, b) => {
      const aTime = new Date(a.timestamp || '').getTime();
      const bTime = new Date(b.timestamp || '').getTime();
      return aTime - bTime;
    });
  }

  if (props.execution) return [];
  if (import.meta.env.DEV) return mockTraces;
  return [];
});

// Execution status
const executionStatus = computed<ExecutionStatus>(() => props.execution?.status ?? 'pending');
const isRunning = computed(() => executionStatus.value === 'running' || executionStatus.value === 'pending');

// Status counts (iteration-aware)
const statusCounts = computed(() => {
  const counts = { completed: 0, failed: 0, running: 0, pending: 0 };

  for (const trace of traces.value) {
    if (trace.isMultiItem && trace.iterations) {
      for (const iteration of trace.iterations) {
        if (iteration.status === 'completed') counts.completed++;
        else if (iteration.status === 'failed') counts.failed++;
        else if (iteration.status === 'running') counts.running++;
        else counts.pending++;
      }
    } else {
      if (trace.status === 'completed') counts.completed++;
      else if (trace.status === 'failed') counts.failed++;
      else if (trace.status === 'running') counts.running++;
      else counts.pending++;
    }
  }
  return counts;
});

// Minimal status badge config
const statusBadgeConfig: Record<ExecutionStatus, { class: string; label: string }> = {
  pending: { class: 'bg-base-200 text-base-content/70', label: 'Pending' },
  running: { class: 'bg-primary/15 text-primary', label: 'Running' },
  paused: { class: 'bg-warning/15 text-warning', label: 'Paused' },
  completed: { class: 'bg-success/15 text-success', label: 'Completed' },
  failed: { class: 'bg-error/15 text-error', label: 'Failed' },
  cancelled: { class: 'bg-base-200 text-base-content/70', label: 'Cancelled' },
  timeout: { class: 'bg-warning/15 text-warning', label: 'Timeout' },
};

// Step status indicator
const stepStatusClass = (status: StepExecutionStatus): string => {
  const map: Record<StepExecutionStatus, string> = {
    pending: 'bg-base-content/15',
    queued: 'bg-info/80',
    running: 'bg-primary animate-pulse',
    completed: 'bg-success',
    failed: 'bg-error',
    skipped: 'bg-base-content/20',
    cancelled: 'bg-base-content/25',
  };
  return map[status] || 'bg-base-content/15';
};

// Format duration
const formatDuration = (us?: number): string => {
  if (!us) return '';
  if (us < 1000) return `${us}µs`;
  if (us < 1_000_000) return `${(us / 1000).toFixed(1)}ms`;
  return `${(us / 1_000_000).toFixed(2)}s`;
};

const selectStep = (stepId: string) => {
  if (localSelectedStepId.value === stepId) return;
  localSelectedStepId.value = stepId;
  activeIterationId.value = null;
  emit('selectStep', stepId);
};

const toggleMultiItemExpansion = (stepId: string) => {
  if (expandedMultiItemSteps.value.has(stepId)) {
    expandedMultiItemSteps.value.delete(stepId);
    activeIterationId.value = null;
  } else {
    expandedMultiItemSteps.value.add(stepId);
    const trace = traces.value.find(t => t.step_id === stepId);
    if (trace?.iterations?.length) activeIterationId.value = trace.iterations[0].id;
  }
};

const getIterationData = (iterationId: string, type: 'input' | 'output') => {
  const trace = selectedTraceEntry.value;
  if (!trace?.iterations) return null;

  const iteration = trace.iterations.find(iter => iter.id === iterationId);
  if (!iteration) return null;

  return type === 'input' ? iteration.input_data : iteration.output_data;
};

const getIterationIndex = (iterationId: string): number => {
  const trace = selectedTraceEntry.value;
  if (!trace?.iterations) return 0;

  const iteration = trace.iterations.find(iter => iter.id === iterationId);
  return iteration?.item_index || 0;
};

// Helper for nice compact “meta line”
const stepMetaLine = (trace: TraceEntry) => {
  const parts: string[] = [];
  if (trace.timestamp) parts.push(trace.timestamp);
  if (trace.step_type_id) parts.push(trace.step_type_id);
  return parts.join(' • ');
};
</script>

<template>
  <div
    class="border-base-200 bg-base-100 flex flex-col overflow-hidden border-t"
    :class="isExpanded ? 'h-80' : 'h-10'"
  >
    <!-- Header (minimal, vercel-ish) -->
    <div
      class="border-base-200 flex h-10 shrink-0 cursor-pointer items-center justify-between border-b px-4"
      :class="isExpanded ? 'bg-base-100' : 'bg-base-100 hover:bg-base-200/40'"
      @click="emit('toggle')"
    >
      <div class="flex items-center gap-3">
        <ChevronUpIcon
          class="h-4 w-4 text-base-content/50 transition-transform"
          :class="{ 'rotate-180': isExpanded }"
        />

        <div class="flex items-center gap-2">
          <span class="text-sm font-medium text-base-content/80">Execution trace</span>
          <span
            class="inline-flex items-center rounded-full px-2 py-0.5 text-[11px] font-medium"
            :class="statusBadgeConfig[executionStatus].class"
          >
            <span class="mr-1.5 h-1.5 w-1.5 rounded-full" :class="stepStatusClass(executionStatus as any)"></span>
            {{ statusBadgeConfig[executionStatus].label }}
          </span>
        </div>
      </div>

      <div class="flex items-center gap-3" @click.stop>
        <!-- Compact status summary -->
        <div class="hidden items-center gap-3 text-xs text-base-content/55 sm:flex">
          <span class="inline-flex items-center gap-1.5">
            <span class="h-1.5 w-1.5 rounded-full bg-success"></span>
            {{ statusCounts.completed }}
          </span>
          <span class="h-3 w-px bg-base-300"></span>
          <span class="inline-flex items-center gap-1.5">
            <span class="h-1.5 w-1.5 rounded-full bg-error"></span>
            {{ statusCounts.failed }}
          </span>
        </div>

        <!-- Actions -->
        <button
          v-if="isRunning"
          class="inline-flex items-center gap-1 rounded-md border border-base-300 bg-base-100 px-2 py-1 text-xs font-medium text-base-content/70 hover:bg-base-200/40"
          @click="emit('cancel')"
        >
          <StopIcon class="h-4 w-4 text-warning" />
          Cancel
        </button>
      </div>
    </div>

    <!-- Body -->
    <div v-if="isExpanded" class="flex flex-1 overflow-hidden">
      <!-- Steps -->
      <aside class="border-base-200 w-[340px] shrink-0 overflow-y-auto border-r">
        <div class="px-2 py-2">
          <div v-if="traces.length === 0" class="py-10 text-center text-base-content/50">
            <ClockIcon class="mx-auto mb-2 h-7 w-7 opacity-40" />
            <p class="text-sm font-medium">No execution data</p>
            <p class="mt-1 text-xs opacity-70">Run a test to see trace output.</p>
          </div>

          <div v-else class="space-y-1">
            <template v-for="trace in traces" :key="trace.id">
              <!-- Multi-item group -->
              <div v-if="trace.isMultiItem" class="rounded-lg">
                <div
                  class="group flex items-center gap-2 rounded-lg px-2.5 py-2 transition-colors"
                  :class="{
                    'bg-base-200/50': localSelectedStepId === trace.step_id,
                    'hover:bg-base-200/40': localSelectedStepId !== trace.step_id,
                  }"
                  @click="selectStep(trace.step_id); toggleMultiItemExpansion(trace.step_id)"
                >
                  <span class="h-2 w-2 rounded-full" :class="stepStatusClass(trace.status)"></span>

                  <div class="min-w-0 flex-1">
                    <div class="flex items-center gap-2">
                      <span class="truncate text-sm font-medium text-base-content/85">
                        {{ trace.step_name }}
                      </span>
                      <span class="rounded-full bg-base-200 px-2 py-0.5 text-[11px] text-base-content/60">
                        {{ trace.items_total }} items
                      </span>
                    </div>

                    <div class="mt-0.5 truncate text-[11px] text-base-content/45">
                      {{ stepMetaLine(trace) }}
                    </div>
                  </div>

                  <span class="shrink-0 font-mono text-[11px] text-base-content/45">
                    {{ formatDuration(trace.duration_us) }}
                  </span>

                  <ExclamationCircleIcon v-if="trace.status === 'failed'" class="h-4 w-4 text-error" />

                  <button
                    class="grid h-6 w-6 place-items-center rounded-md border border-transparent text-base-content/50 hover:border-base-300 hover:bg-base-100"
                    @click.stop="toggleMultiItemExpansion(trace.step_id)"
                    aria-label="Toggle iterations"
                  >
                    <ChevronUpIcon
                      class="h-4 w-4 transition-transform"
                      :class="{ 'rotate-180': expandedMultiItemSteps.has(trace.step_id) }"
                    />
                  </button>
                </div>

                <!-- Iterations (clean indented list instead of heavy timeline) -->
                <div
                  v-if="expandedMultiItemSteps.has(trace.step_id)"
                  class="ml-10 mt-1 space-y-1 border-l border-base-300 pl-3"
                >
                  <button
                    v-for="iteration in trace.iterations"
                    :key="iteration.id"
                    class="flex w-full items-center justify-between rounded-md px-2 py-1.5 text-left transition-colors"
                    :class="activeIterationId === iteration.id ? 'bg-base-200/60' : 'hover:bg-base-200/40'"
                    @click.stop="
                      selectStep(trace.step_id);
                      activeIterationId = iteration.id
                    "
                  >
                    <div class="flex min-w-0 items-center gap-2">
                      <span class="h-1.5 w-1.5 rounded-full" :class="stepStatusClass(iteration.status)"></span>
                      <span class="truncate text-xs text-base-content/70">
                        Item #{{ (iteration.item_index || 0) + 1 }}
                      </span>
                    </div>
                    <span class="ml-3 shrink-0 font-mono text-[11px] text-base-content/45">
                      {{ formatDuration(iteration.duration_us) }}
                    </span>
                  </button>
                </div>
              </div>

              <!-- Single item -->
              <div
                v-else
                class="group flex items-center gap-2 rounded-lg px-2.5 py-2 transition-colors"
                :class="{
                  'bg-base-200/50': localSelectedStepId === trace.step_id,
                  'hover:bg-base-200/40': localSelectedStepId !== trace.step_id,
                }"
                @click="selectStep(trace.step_id)"
              >
                <span class="h-2 w-2 rounded-full" :class="stepStatusClass(trace.status)"></span>

                <div class="min-w-0 flex-1">
                  <div class="truncate text-sm font-medium text-base-content/85">
                    {{ trace.step_name }}
                  </div>
                  <div class="mt-0.5 truncate text-[11px] text-base-content/45">
                    {{ stepMetaLine(trace) }}
                  </div>
                </div>

                <span class="shrink-0 font-mono text-[11px] text-base-content/45">
                  {{ formatDuration(trace.duration_us) }}
                </span>

                <ExclamationCircleIcon v-if="trace.status === 'failed'" class="h-4 w-4 text-error" />
              </div>
            </template>
          </div>
        </div>
      </aside>

      <!-- Detail -->
      <section class="flex flex-1 flex-col overflow-hidden bg-base-100">
        <!-- Detail header with tabs -->
        <div class="border-base-200 flex items-center justify-between border-b px-5 py-3">
          <div class="min-w-0">
            <div class="truncate text-sm font-semibold text-base-content/85">
              {{ selectedTraceEntry?.step_name ?? 'Select a step' }}
            </div>
            <div class="mt-0.5 text-[11px] text-base-content/50">
              <template v-if="selectedTraceEntry?.isMultiItem">
                {{ selectedTraceEntry.items_total }} items • {{ formatDuration(selectedTraceEntry.duration_us) }}
              </template>
              <template v-else-if="localSelectedStepId">
                Step ID: <span class="font-mono">{{ localSelectedStepId }}</span>
              </template>
              <template v-else>Inspect inputs/outputs for a node.</template>
            </div>
          </div>

          <div class="flex items-center rounded-lg bg-base-200/60 p-1">
            <button
              v-for="tab in ['input', 'output'] as const"
              :key="tab"
              class="rounded-md px-3 py-1 text-xs font-medium capitalize transition-all"
              :class="
                activeTab === tab
                  ? 'bg-base-100 text-base-content shadow-sm'
                  : 'text-base-content/55 hover:text-base-content/80'
              "
              @click="activeTab = tab"
            >
              {{ tab }}
            </button>
          </div>
        </div>

        <div class="custom-scrollbar flex-1 overflow-y-auto px-5 py-4">
          <!-- Multi-item step detail -->
          <div v-if="selectedTraceEntry?.isMultiItem" class="space-y-4">
            <div v-if="selectedTraceEntry.iterations && selectedTraceEntry.iterations.length > 0" class="space-y-2">
              <div class="text-xs font-semibold text-base-content/70">
                Iteration #{{ getIterationIndex(activeIterationId || selectedTraceEntry.iterations[0].id) + 1 }} — {{ activeTab }}
              </div>

              <pre
                class="rounded-lg border border-base-200 bg-base-100 p-3 font-mono text-xs text-base-content/75"
              >{{
                JSON.stringify(getIterationData(activeIterationId || selectedTraceEntry.iterations[0].id, activeTab), null, 2)
              }}</pre>
            </div>

            <div v-else class="rounded-lg border border-base-200 bg-base-100 p-4 text-sm text-base-content/55">
              No iterations available.
            </div>
          </div>

          <!-- Single-item step detail -->
          <div v-else class="space-y-3">
            <template v-if="localSelectedStepId">
              <template v-if="activeTab === 'input'">
                <div v-if="selectedStepExecution?.input_data">
                  <pre
                    class="rounded-lg border border-base-200 bg-base-100 p-3 font-mono text-xs text-base-content/75"
                  >{{ JSON.stringify(selectedStepExecution.input_data, null, 2) }}</pre>
                </div>
                <div v-else class="rounded-lg border border-base-200 bg-base-100 p-4 text-sm text-base-content/55">
                  No input available yet.
                </div>
              </template>

              <template v-else>
                <div v-if="selectedStepExecution?.output_data">
                  <pre
                    class="rounded-lg border border-base-200 bg-base-100 p-3 font-mono text-xs text-base-content/75"
                  >{{ JSON.stringify(selectedStepExecution.output_data, null, 2) }}</pre>
                </div>
                <div v-else class="rounded-lg border border-base-200 bg-base-100 p-4 text-sm text-base-content/55">
                  No output available yet.
                </div>
              </template>
            </template>

            <div v-else class="rounded-lg border border-base-200 bg-base-100 p-4 text-sm text-base-content/55">
              Select a step from the left to view data.
            </div>
          </div>
        </div>
      </section>
    </div>
  </div>
</template>

<style scoped>
.custom-scrollbar::-webkit-scrollbar {
  width: 8px;
}
.custom-scrollbar::-webkit-scrollbar-thumb {
  background: color-mix(in oklch, var(--color-base-content) 12%, transparent);
  border-radius: 999px;
}
.custom-scrollbar::-webkit-scrollbar-track {
  background: transparent;
}
</style>
