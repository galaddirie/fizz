import { ref, computed, watch, type InjectionKey } from 'vue';
import { watchDebounced } from '@vueuse/core';
import type { Node } from '@vue-flow/core';
import type {
    EditorState,
    Execution,
    StepExecution,
    StepNodeData,
    StepType,
} from '@/types/workflow';
import type {
    ConfigSchemaField,
    ConfigSchema,
    ConfigField,
    ExtendedFieldType
} from '@/types/configSchema';
import { toRecord } from '@/lib/dataUtils';

import { useExpressionPreviews } from './useExpressionPreviews';
import { useSubnodes } from './useSubnodes';
import { useStepExecution } from './useStepExecution';
import { usePinnedOutputs } from './usePinnedOutputs';
import { useInputData } from './useInputData';
import { useExpressionHelpers } from './useExpressionHelpers';
import { useContextExplorer } from './useContextExplorer';

export interface UseStepConfigProps {
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
    incomingConnectionsByTargetInput?: Record<string, Record<string, string[]>>;
    upstreamStepIds?: Record<string, string[]>;
}

export function useStepConfig(props: UseStepConfigProps, emit: (...args: any[]) => void) {
    // --- Core state ---
    const fieldModes = ref<Record<string, 'literal' | 'expression'>>({});
    const fieldValues = ref<Record<string, unknown>>({});
    const fieldErrors = ref<Record<string, string>>({});
    const isEditingName = ref(false);
    const editName = ref('');
    const canEdit = computed(() => props.canEdit ?? true);

    // --- Unsaved changes tracking ---
    const originalValues = ref<Record<string, unknown>>({});
    const originalName = ref('');
    const showCloseConfirmation = ref(false);
    const hasFieldErrors = computed(() => Object.keys(fieldErrors.value).length > 0);

    const hasUnsavedChanges = computed(() => {
        if (!canEdit.value) return false;
        if (editName.value !== originalName.value) return true;

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

    const isManualTriggerStep = computed(() => {
        return props.stepType?.id === 'manual_input' || props.node?.data?.type_id === 'manual_input';
    });

    const initializeFromNode = (node: Node<StepNodeData>) => {
        const nodeData = node.data!;
        const config = nodeData.config || {};
        const schema = (props.stepType?.config_schema as ConfigSchema | undefined)?.properties || {};
        const allKeys = new Set([...Object.keys(schema), ...Object.keys(config)]);

        if (isManualTriggerStep.value && !Object.prototype.hasOwnProperty.call(config, 'test_data')) {
            allKeys.delete('test_data');
        }

        const modes: Record<string, 'literal' | 'expression'> = {};
        const values: Record<string, unknown> = {};

        allKeys.forEach(key => {
            const schemaField = schema[key] ?? {};
            const rawValue = config[key] ?? schemaField.default;
            const isSearchField = schemaField.ui?.component === 'search';
            const isExpr =
                !isSearchField &&
                typeof rawValue === 'string' &&
                (rawValue.includes('{{') || rawValue.includes('{%'));

            modes[key] = isExpr ? 'expression' : 'literal';
            values[key] = rawValue ?? null;
        });

        fieldModes.value = modes;
        fieldValues.value = values;
        fieldErrors.value = {};
        editName.value = nodeData.name || '';
        isEditingName.value = false;

        originalValues.value = { ...values };
        originalName.value = editName.value;
        showCloseConfirmation.value = false;
    };

    // --- Init watcher: populate fields/modes on open ---
    watch(
        [() => props.node?.id ?? null, () => props.node?.data?.type_id ?? null, () => props.isOpen],
        ([nodeId, _typeId, open], previousValues) => {
            const [previousNodeId, previousTypeId, wasOpen] = previousValues ?? [null, null, false];
            const node = props.node;

            if (!open || !node || !node.data) return;

            const shouldInitialize =
                !wasOpen ||
                nodeId !== previousNodeId ||
                props.node?.data?.type_id !== previousTypeId;

            if (!shouldInitialize) return;

            initializeFromNode(node);
        },
        { immediate: true }
    );

    const hasExpressionSyntax = (value: unknown) =>
        typeof value === 'string' && (value.includes('{{') || value.includes('{%'));

    // --- Expression preview debounce watcher ---
    watchDebounced(
        [fieldValues, fieldModes],
        () => {
            if (!canEdit.value) return;
            if (!props.isOpen || !props.node) return;

            Object.entries(fieldValues.value).forEach(([key, value]) => {
                if (
                    fieldModes.value[key] === 'expression' &&
                    typeof value === 'string' &&
                    props.node
                ) {
                    emit('preview_expression', {
                        step_id: props.node.id,
                        field_key: key,
                        expression: value,
                    });
                }
            });
        },
        { debounce: 300, deep: true, immediate: true }
    );

    // --- Modal lifecycle ---
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
        if (hasFieldErrors.value) return;

        emit('save', {
            id: props.node?.id,
            name: editName.value,
            config: { ...fieldValues.value },
        });

        originalValues.value = { ...fieldValues.value };
        originalName.value = editName.value;
        emit('close');
    };

    // --- Field management ---
    const setFieldMode = (field: string, mode: 'literal' | 'expression') => {
        if (!canEdit.value) return;
        fieldModes.value[field] = mode;
    };

    const handleFieldValidationUpdate = (fieldKey: string, error: string | null) => {
        if (error) {
            fieldErrors.value[fieldKey] = error;
            return;
        }

        delete fieldErrors.value[fieldKey];
    };

    const isStructuredValue = (value: unknown) =>
        Array.isArray(value) || (value !== null && typeof value === 'object');

    const manualTriggerTestDataField = computed<ConfigField | null>(() => {
        if (!isManualTriggerStep.value) return null;

        const schema =
            (props.stepType?.config_schema as ConfigSchema | undefined)?.properties?.test_data ?? {};

        return {
            ...schema,
            key: 'test_data',
            label: schema.title || 'Test Data',
            description:
                schema.description ||
                'Saved on this trigger and used for Run Test and Run from Here.',
            type: 'json',
            expressionCapable: false,
        };
    });

    const manualTriggerInputSchema = computed(() => {
        const value =
            fieldValues.value['input_schema'] ??
            props.node?.data?.config?.input_schema ??
            null;

        if (value === null || value === undefined) return null;
        return value;
    });

    const fields = computed<ConfigField[]>(() => {
        if (!props.node || !props.node.data) return [];

        const schema = (props.stepType?.config_schema as ConfigSchema | undefined)?.properties || {};
        const config = props.node.data.config || {};
        const allKeys = new Set([...Object.keys(schema), ...Object.keys(config)]);

        if (isManualTriggerStep.value) {
            allKeys.delete('test_data');
        }

        return Array.from(allKeys).map(key => {
            const schemaField: ConfigSchemaField = schema[key] ?? {};
            const uiComponent = (schemaField as any).ui?.component;
            const format = schemaField.format;
            const typeStr = schemaField.type;
            const rawValue = config[key] ?? schemaField.default;

            let inferredType: ExtendedFieldType = 'text';
            if (uiComponent === 'slot') inferredType = 'json';
            else if (uiComponent === 'search') inferredType = 'search';
            else if (uiComponent === 'select') inferredType = 'select';
            else if (uiComponent === 'json') inferredType = 'json';
            else if (schemaField.enum && schemaField.enum.length > 0) inferredType = 'select';
            else if (
                format === 'json' ||
                typeStr === 'object' ||
                typeStr === 'array' ||
                isStructuredValue(rawValue)
            ) {
                inferredType = 'json';
            }
            else if (typeStr === 'string' && format === 'textarea') inferredType = 'textarea';
            else if (typeStr === 'number' || typeStr === 'integer') inferredType = 'number';
            else if (typeStr === 'boolean') inferredType = 'boolean';

            return {
                ...schemaField,
                key,
                label: schemaField.title || key.replace(/_/g, ' ').replace(/\b\w/g, l => l.toUpperCase()),
                description: schemaField.description,
                type: inferredType as ExtendedFieldType,
                expressionCapable: uiComponent !== 'slot',
            };
        });
    });

    const fieldByKey = computed(() => {
        return fields.value.reduce<Record<string, any>>((acc, field) => {
            acc[field.key] = field;
            return acc;
        }, {});
    });

    const handleFieldValueUpdate = (fieldKey: string, value: unknown) => {
        fieldValues.value[fieldKey] = value;
        const field = fieldByKey.value[fieldKey];
        const isSearchField = field?.ui?.component === 'search';
        if (!isSearchField && hasExpressionSyntax(value)) {
            fieldModes.value[fieldKey] = 'expression';
        }
    };

    const handleManualTriggerTestDataUpdate = (value: unknown) => {
        if (value === null) {
            const { test_data: _removed, ...rest } = fieldValues.value;
            fieldValues.value = rest;
            return;
        }

        fieldValues.value['test_data'] = value;
    };

    const nodeId = computed(() => props.node?.id ?? '');
    const stepNameById = computed(() => props.stepNameById ?? {});

    // --- Sub-composables ---
    const previews = useExpressionPreviews({
        node: () => props.node,
        expressionPreviews: () => props.expressionPreviews,
    });

    const subnodes = useSubnodes({
        node: () => props.node,
        stepType: () => props.stepType,
        stepNameById: () => props.stepNameById,
        incomingStepIds: () => props.incomingStepIds,
        incomingConnectionsByTargetInput: () => props.incomingConnectionsByTargetInput,
    });

    const execution = useStepExecution({
        node: () => props.node,
        stepExecutions: () => props.stepExecutions ?? [],
    });

    const evaluatedConfig = computed<Record<string, unknown>>(() => {
        const metadata = toRecord(execution.activeStepExecution.value?.metadata);
        const evaluated = toRecord(metadata?.evaluated_config);
        return evaluated ?? {};
    });

    const pinned = usePinnedOutputs({
        node: () => props.node,
        editorState: () => props.editorState,
        canEdit,
        activeStepExecution: execution.activeStepExecution,
        emit,
    });

    const inputData = useInputData({
        node: () => props.node,
        execution: () => props.execution,
        canEdit,
        resolveLatestExecution: execution.resolveLatestExecution,
        selectedItemIndex: execution.selectedItemIndex,
        isTriggerStep: subnodes.isTriggerStep,
        directUpstreamStepIds: subnodes.directUpstreamStepIds,
        inputIndexLabels: subnodes.inputIndexLabels,
        emit,
    });

    const expressionHelpers = useExpressionHelpers({
        node: () => props.node,
        stepNameById: () => props.stepNameById,
        editName,
        currentInputState: inputData.currentInputState,
        directUpstreamStepIds: subnodes.directUpstreamStepIds,
        inputIndexLabels: subnodes.inputIndexLabels,
    });

    const contextExplorer = useContextExplorer({
        node: () => props.node,
        execution: () => props.execution,
        stepExecutions: () => props.stepExecutions ?? [],
        stepNameById: () => props.stepNameById,
        upstreamStepIds: () => props.upstreamStepIds,
        currentInputState: inputData.currentInputState,
    });

    // Destructure resolveLatestExecution out - it's internal, not part of the provide/inject contract
    const { resolveLatestExecution: _, ...executionPublic } = execution;

    return {
        // Core (inline)
        fieldModes,
        fieldValues,
        fieldErrors,
        isEditingName,
        editName,
        canEdit,
        originalValues,
        originalName,
        showCloseConfirmation,
        hasFieldErrors,
        hasUnsavedChanges,
        closeModal,
        confirmClose,
        cancelClose,
        saveConfig,
        setFieldMode,
        handleFieldValidationUpdate,
        fields,
        fieldByKey,
        handleFieldValueUpdate,
        isManualTriggerStep,
        manualTriggerTestDataField,
        manualTriggerInputSchema,
        handleManualTriggerTestDataUpdate,
        nodeId,
        stepNameById,
        evaluatedConfig,
        // Sub-composables
        ...previews,
        ...subnodes,
        ...executionPublic,
        ...pinned,
        ...inputData,
        ...expressionHelpers,
        ...contextExplorer,
    };
}

export type StepConfigState = ReturnType<typeof useStepConfig>;
export const StepConfigKey: InjectionKey<StepConfigState> = Symbol('StepConfig');
