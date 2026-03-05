import { computed, type ComputedRef } from 'vue';
import type { Node } from '@vue-flow/core';
import type { StepNodeData } from '@/shared/ui/workflow-scene/types';
import type { EditorState, StepExecution } from '@/types/workflow';

interface UsePinnedOutputsOptions {
    node: () => Node<StepNodeData> | null;
    editorState: () => EditorState | undefined;
    canEdit: ComputedRef<boolean>;
    activeStepExecution: ComputedRef<StepExecution | null>;
    emit: (...args: any[]) => void;
}

export function usePinnedOutputs({
    node,
    editorState,
    canEdit,
    activeStepExecution,
    emit,
}: UsePinnedOutputsOptions) {
    const pinnedOutputs = computed(() => editorState()?.pinned_outputs ?? {});

    const hasPinnedOutput = computed(() => {
        const stepId = node()?.id;
        if (!stepId) return false;
        return Object.prototype.hasOwnProperty.call(pinnedOutputs.value, stepId);
    });

    const pinnedOutput = computed(() => {
        const n = node();
        if (!n?.id || !hasPinnedOutput.value) return null;
        return pinnedOutputs.value[n.id];
    });

    const canPinOutput = computed(() => {
        const execution = activeStepExecution.value;
        return !!execution && execution.status === 'completed';
    });

    const pinButtonLabel = computed(() => (hasPinnedOutput.value ? 'Update Pin' : 'Pin Output'));

    const pinOutput = () => {
        if (!canEdit.value) return;
        const n = node();
        if (!n || !activeStepExecution.value || !canPinOutput.value) return;
        emit('pin_output', {
            step_id: n.id,
            output_data: activeStepExecution.value.output_data ?? null,
            item_index: activeStepExecution.value.item_index ?? null,
        });
    };

    const unpinOutput = () => {
        if (!canEdit.value) return;
        const n = node();
        if (!n) return;
        emit('unpin_output', { step_id: n.id });
    };

    return {
        pinnedOutputs,
        hasPinnedOutput,
        pinnedOutput,
        canPinOutput,
        pinButtonLabel,
        pinOutput,
        unpinOutput,
    };
}
