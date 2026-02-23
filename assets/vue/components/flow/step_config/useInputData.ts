import { computed, type ComputedRef, type Ref } from 'vue';
import type { Node } from '@vue-flow/core';
import type {
    Execution,
    StepExecution,
    StepExecutionStatus,
    StepNodeData,
} from '@/types/workflow';
import { unwrapData } from '@/lib/dataUtils';

interface UseInputDataOptions {
    node: () => Node<StepNodeData> | null;
    execution: () => Execution | null | undefined;
    canEdit: ComputedRef<boolean>;
    resolveLatestExecution: (stepId: string, itemIndex: number | null) => StepExecution | null;
    selectedItemIndex: Ref<number | null>;
    isTriggerStep: ComputedRef<boolean>;
    directUpstreamStepIds: ComputedRef<string[]>;
    inputIndexLabels: ComputedRef<string[]>;
    emit: (...args: any[]) => void;
}

export function useInputData({
    node,
    execution,
    canEdit,
    resolveLatestExecution,
    selectedItemIndex,
    isTriggerStep,
    directUpstreamStepIds,
    inputIndexLabels,
    emit,
}: UseInputDataOptions) {
    const currentInputState = computed(() => {
        const upstreamIds = directUpstreamStepIds.value;
        const itemIndex = selectedItemIndex.value;

        if (!node()) {
            return { status: 'missing', reason: 'no_step', data: null };
        }

        if (upstreamIds.length === 0) {
            const triggerData = execution()?.trigger?.data;
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
        const n = node();
        if (!n) return;
        emit('run_node', n.id);
    };

    return {
        currentInputState,
        currentInputEmptyState,
        runInputLabel,
        runInput,
    };
}
