import { ref, computed, watch } from 'vue';
import type { Node } from '@vue-flow/core';
import type { StepExecution, StepNodeData } from '@/types/workflow';

interface UseStepExecutionOptions {
    node: () => Node<StepNodeData> | null;
    stepExecutions: () => StepExecution[];
}

export function useStepExecution({ node, stepExecutions }: UseStepExecutionOptions) {
    const stepExecutionsForStep = computed(() => {
        const n = node();
        if (!n) return [];
        return stepExecutions()
            .filter(se => se.step_id === n.id)
            .sort((a, b) => (a.item_index ?? -1) - (b.item_index ?? -1));
    });

    const isMultiItemStep = computed(() => {
        const executions = stepExecutionsForStep.value;
        if (executions.length === 0) return false;
        const first = executions[0];
        return (first.items_total ?? 0) > 1 || executions.length > 1;
    });

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

    const totalItems = computed(() => {
        const stats = itemStats.value;
        return stats?.itemsTotal ?? stepExecutionsForStep.value.length;
    });

    const selectedItemIndex = ref<number | null>(null);

    const syncSelectedItemIndex = () => {
        if (!isMultiItemStep.value) {
            selectedItemIndex.value = null;
            return;
        }

        const maxIndex = totalItems.value - 1;

        if (maxIndex < 0) {
            selectedItemIndex.value = null;
            return;
        }

        if (selectedItemIndex.value === null) {
            selectedItemIndex.value = 0;
            return;
        }

        selectedItemIndex.value = Math.min(Math.max(selectedItemIndex.value, 0), maxIndex);
    };

    watch(
        () => node()?.id,
        () => {
            selectedItemIndex.value = null;
            syncSelectedItemIndex();
        },
        { immediate: true }
    );

    watch(
        [isMultiItemStep, totalItems, () => stepExecutionsForStep.value.length],
        () => {
            syncSelectedItemIndex();
        },
        { immediate: true }
    );

    const activeStepExecution = computed(() => {
        const executions = stepExecutionsForStep.value;
        if (executions.length === 0) return null;

        if (isMultiItemStep.value && selectedItemIndex.value !== null) {
            return executions.find(e => e.item_index === selectedItemIndex.value) || executions[0];
        }

        return executions[0];
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
        const executions = stepExecutions().filter(se => se.step_id === stepId);
        if (executions.length === 0) return null;

        if (itemIndex !== null) {
            const matching = executions.filter(se => se.item_index === itemIndex);
            const latestMatching = pickLatestExecution(matching);
            if (latestMatching) return latestMatching;
        }

        const singleItemExecutions = executions.filter(se => se.item_index === null || se.item_index === undefined);
        return pickLatestExecution(singleItemExecutions.length > 0 ? singleItemExecutions : executions);
    };

    return {
        stepExecutionsForStep,
        isMultiItemStep,
        itemStats,
        selectedItemIndex,
        activeStepExecution,
        resolveLatestExecution,
    };
}
