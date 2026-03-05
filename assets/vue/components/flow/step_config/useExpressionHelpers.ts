import { type ComputedRef, type Ref } from 'vue';
import type { Node } from '@vue-flow/core';
import type { StepNodeData } from '@/shared/ui/workflow-scene/types';

interface UseExpressionHelpersOptions {
    node: () => Node<StepNodeData> | null;
    stepNameById: () => Record<string, string> | undefined;
    editName: Ref<string>;
    currentInputState: ComputedRef<{ status: string; reason: string | null; data: unknown }>;
    directUpstreamStepIds: ComputedRef<string[]>;
    inputIndexLabels: ComputedRef<string[]>;
}

const slugify = (text: string) => {
    return text
        .toLowerCase()
        .replace(/[^\w\s]/g, '')
        .replace(/[\s]+/g, '_')
        .replace(/_+/g, '_')
        .replace(/^_|_$/g, '');
};

export function useExpressionHelpers({
    node,
    stepNameById,
    editName,
    currentInputState,
    directUpstreamStepIds,
    inputIndexLabels,
}: UseExpressionHelpersOptions) {
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
            case 'steps': {
                if (!key) return `{{ steps }}`;
                const n = node();
                const currentStepId = n?.id;
                const currentStepName = n?.data?.name || '';
                const isCurrentStep = key === currentStepId || key === currentStepName;
                const resolvedName = isCurrentStep ? editName.value : stepNameById()?.[key];
                const stepName = resolvedName && resolvedName.length > 0 ? resolvedName : key;
                const stepKey = stepName && stepName.length > 0 ? slugify(stepName) : key;
                return `{{ steps["${stepKey}"].json }}`;
            }
            default:
                return `{{ ${sectionId}${path} }}`;
        }
    };

    const copyExpression = (sectionId: string, key?: string) => {
        const expression = getExpressionFor(sectionId, key);
        navigator.clipboard.writeText(expression);
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

    return {
        getExpressionFor,
        copyExpression,
        formatSectionKey,
    };
}
