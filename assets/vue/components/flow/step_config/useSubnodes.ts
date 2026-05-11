import { computed } from 'vue';
import type { Node } from '@vue-flow/core';
import type { StepNodeData, StepSubnodeInput, StepType } from '@/types/workflow';

interface UseSubnodesOptions {
    node: () => Node<StepNodeData> | null;
    stepType: () => StepType | null | undefined;
    stepNameById: () => Record<string, string> | undefined;
    incomingStepIds: () => Record<string, string[]> | undefined;
    incomingConnectionsByTargetInput: () => Record<string, Record<string, string[]>> | undefined;
}

export function useSubnodes({
    node,
    stepType,
    stepNameById,
    incomingStepIds,
    incomingConnectionsByTargetInput,
}: UseSubnodesOptions) {
    const isTriggerStep = computed(() => {
        return (
            stepType()?.step_kind === 'trigger' || node()?.data?.step_kind === 'trigger' || false
        );
    });

    const directUpstreamStepIds = computed(() => {
        const n = node();
        if (!n) return [];
        return incomingStepIds()?.[n.id] ?? [];
    });

    const inputIndexLabels = computed(() => {
        const upstreamIds = directUpstreamStepIds.value;
        return upstreamIds.map(stepId => stepNameById()?.[stepId] || stepId);
    });

    const subnodeInputs = computed<StepSubnodeInput[]>(() => {
        const typeInputs = stepType()?.subnode_inputs;
        if (typeInputs?.length) return typeInputs;
        return node()?.data?.subnode_inputs ?? [];
    });

    const incomingConnectionsByTargetInputForStep = computed<Record<string, string[]>>(() => {
        const n = node();
        if (!n) return {};
        return incomingConnectionsByTargetInput()?.[n.id] ?? {};
    });

    const subnodeInputRows = computed(() => {
        return subnodeInputs.value.map(input => {
            const inputId = input.id;
            const sourceStepIds = incomingConnectionsByTargetInputForStep.value[inputId] ?? [];
            const sourceStepNames = sourceStepIds.map(stepId => stepNameById()?.[stepId] || stepId);

            return {
                input,
                sourceStepIds,
                sourceStepNames,
                isConnected: sourceStepIds.length > 0,
            };
        });
    });

    return {
        isTriggerStep,
        directUpstreamStepIds,
        inputIndexLabels,
        subnodeInputs,
        incomingConnectionsByTargetInputForStep,
        subnodeInputRows,
    };
}
