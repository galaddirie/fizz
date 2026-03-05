import { computed } from 'vue';
import type { Node } from '@vue-flow/core';
import type { StepNodeData } from '@/shared/ui/workflow-scene/types';
import type { StepSubnodeSlot, StepType } from '@/types/workflow';

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

    const subnodeSlots = computed<StepSubnodeSlot[]>(() => {
        const typeSlots = stepType()?.subnode_slots;
        if (typeSlots?.length) return typeSlots;
        return node()?.data?.subnode_slots ?? [];
    });

    const incomingConnectionsByTargetInputForStep = computed<Record<string, string[]>>(() => {
        const n = node();
        if (!n) return {};
        return incomingConnectionsByTargetInput()?.[n.id] ?? {};
    });

    const subnodeSlotRows = computed(() => {
        return subnodeSlots.value.map(slot => {
            const slotId = slot.id;
            const sourceStepIds = incomingConnectionsByTargetInputForStep.value[slotId] ?? [];
            const sourceStepNames = sourceStepIds.map(stepId => stepNameById()?.[stepId] || stepId);

            return {
                slot,
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
        subnodeSlots,
        incomingConnectionsByTargetInputForStep,
        subnodeSlotRows,
    };
}
