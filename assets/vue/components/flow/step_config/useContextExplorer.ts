import { ref, computed, type ComputedRef } from 'vue';
import type { Node } from '@vue-flow/core';
import type { StepNodeData } from '@/shared/ui/workflow-scene/types';
import type { Execution, StepExecution } from '@/types/workflow';
import { unwrapData } from '@/lib/dataUtils';

interface UseContextExplorerOptions {
    node: () => Node<StepNodeData> | null;
    execution: () => Execution | null | undefined;
    stepExecutions: () => StepExecution[];
    stepNameById: () => Record<string, string> | undefined;
    upstreamStepIds: () => Record<string, string[]> | undefined;
    currentInputState: ComputedRef<{ status: string; reason: string | null; data: unknown }>;
}

const toRecord = (value: unknown): Record<string, unknown> | null => {
    if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
    return value as Record<string, unknown>;
};

export function useContextExplorer({
    node,
    execution,
    stepExecutions,
    stepNameById,
    upstreamStepIds,
    currentInputState,
}: UseContextExplorerOptions) {
    const searchQuery = ref('');

    const expandedSections = ref<Record<string, boolean>>({
        json: true,
        trigger: true,
        steps: true,
        variables: true,
    });

    const toggleSection = (id: string) => {
        expandedSections.value[id] = !expandedSections.value[id];
    };

    const contextData = computed(() => {
        const n = node();
        const upIds = n ? upstreamStepIds()?.[n.id] || [] : [];
        const metadata = toRecord(execution()?.metadata);
        const extras = toRecord(metadata?.extras);

        const steps =
            stepExecutions().reduce<Record<string, { json: unknown }>>((acc, se) => {
                if (!upIds.includes(se.step_id)) return acc;

                const stepName = stepNameById()?.[se.step_id];
                const key = stepName && stepName.length > 0 ? stepName : se.step_id;

                acc[key] = { json: unwrapData(se.output_data) };
                return acc;
            }, {});

        return {
            json: currentInputState.value.data,
            trigger: execution()?.trigger?.data || {},
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
                icon: 'ArrowRightOnRectangleIcon',
                data: wrapPrimitive(data.json, 'json'),
            },
            {
                id: 'trigger',
                label: 'Trigger Data',
                icon: 'BoltIcon',
                data: wrapPrimitive(data.trigger, 'trigger'),
            },
            { id: 'steps', label: 'Upstream Steps', icon: 'CpuChipIcon', data: data.steps },
            {
                id: 'variables',
                label: 'Workflow Variables',
                icon: 'VariableIcon',
                data: wrapPrimitive(data.variables, 'variables'),
            },
            {
                id: 'request',
                label: 'Request Metadata',
                icon: 'GlobeAltIcon',
                data: wrapPrimitive(data.request, 'request'),
            },
        ];
    });

    return {
        searchQuery,
        expandedSections,
        toggleSection,
        contextData,
        explorerData,
    };
}
