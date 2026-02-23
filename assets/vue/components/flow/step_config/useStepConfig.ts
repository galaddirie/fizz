import { ref, computed, watch } from 'vue';
import { watchDebounced } from '@vueuse/core';
import type { Node } from '@vue-flow/core';
import type {
    CredentialOption,
    EditorState,
    Execution,
    StepExecution,
    StepExecutionStatus,
    StepNodeData,
    StepSubnodeSlot,
    StepType,
} from '@/types/workflow';
import type {
    ConfigSchemaField,
    ConfigSchema,
    ConfigField,
    ExtendedFieldType
} from '@/types/configSchema';
import { unwrapData, formatDataForDisplay } from '@/lib/dataUtils';

interface ErrorPayload {
    type: 'parse_error' | 'render_error';
    message?: string;
    errors?: string[];
    line?: number;
    column?: number;
    text: string;
}

export interface UseStepConfigProps {
    node: Node<StepNodeData> | null;
    isOpen: boolean;
    canEdit?: boolean;
    stepType?: StepType | null;
    credentialOptions?: CredentialOption[];
    execution?: Execution | null;
    stepExecutions?: StepExecution[];
    expressionPreviews?: Record<string, unknown>;
    editorState?: EditorState;
    stepNameById?: Record<string, string>;
    incomingStepIds?: Record<string, string[]>;
    incomingConnectionsByTargetInput?: Record<string, Record<string, string[]>>;
    upstreamStepIds?: Record<string, string[]>;
}

export function useStepConfig(props: UseStepConfigProps, emit: any) {
    const activeTab = ref<'config' | 'output'>('config');
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

    watch(
        [() => props.node, () => props.isOpen],
        ([newNode, open]) => {
            if (open && newNode && newNode.data) {
                const config = newNode.data.config || {};
                const schema = (props.stepType?.config_schema as ConfigSchema | undefined)?.properties || {};
                const allKeys = new Set([...Object.keys(schema), ...Object.keys(config)]);
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
                editName.value = newNode.data.name || '';
                isEditingName.value = false;

                originalValues.value = { ...values };
                originalName.value = editName.value;
                showCloseConfirmation.value = false;
            }
        },
        { immediate: true }
    );

    const hasExpressionSyntax = (value: unknown) =>
        typeof value === 'string' && (value.includes('{{') || value.includes('{%'));

    watchDebounced(
        [fieldValues, fieldModes],
        () => {
            if (!canEdit.value) return;
            if (!props.isOpen || !props.node) return;

            const newValues = fieldValues.value;

            Object.entries(newValues).forEach(([key, value]) => {
                if (
                    fieldModes.value[key] === 'expression' &&
                    fieldSupportsExpression(key) &&
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

        originalValues.value = { ...fieldValues.value };
        originalName.value = editName.value;

        emit('close');
    };

    const setFieldMode = (field: string, mode: 'literal' | 'expression') => {
        if (!canEdit.value) return;
        if (!fieldSupportsExpression(field)) return;
        fieldModes.value[field] = mode;
    };

    const fields = computed<ConfigField[]>(() => {
        if (!props.node || !props.node.data) return [];

        const schema = (props.stepType?.config_schema as ConfigSchema | undefined)?.properties || {};
        const config = props.node.data.config || {};

        const allKeys = new Set([...Object.keys(schema), ...Object.keys(config)]);

        return Array.from(allKeys).map(key => {
            const schemaField: ConfigSchemaField = schema[key] ?? {};

            const uiComponent = (schemaField as any).ui?.component;
            const format = schemaField.format;
            const typeStr = schemaField.type;

            let inferredType = 'text';
            if (uiComponent === 'search') inferredType = 'search';
            else if (uiComponent === 'select') inferredType = 'select';
            else if (schemaField.enum && schemaField.enum.length > 0) inferredType = 'select';
            else if (format === 'json') inferredType = 'json';
            else if (typeStr === 'string' && format === 'textarea') inferredType = 'textarea';
            else if (typeStr === 'number' || typeStr === 'integer') inferredType = 'number';
            else if (typeStr === 'boolean') inferredType = 'boolean';

            return {
                ...schemaField,
                key,
                label: schemaField.title || key.replace(/_/g, ' ').replace(/\b\w/g, l => l.toUpperCase()),
                description: schemaField.description,
                type: inferredType as ExtendedFieldType,
                expressionCapable: true,
            };
        });
    });

    const fieldByKey = computed(() => {
        return fields.value.reduce<Record<string, any>>((acc, field) => {
            acc[field.key] = field;
            return acc;
        }, {});
    });

    const fieldSupportsExpression = (fieldKey: string) => {
        return true;
    };

    const handleFieldValueUpdate = (fieldKey: string, value: unknown) => {
        fieldValues.value[fieldKey] = value;

        if (!fieldSupportsExpression(fieldKey)) return;
        const field = fieldByKey.value[fieldKey];
        const isSearchField = field?.ui?.component === 'search';

        if (!isSearchField && hasExpressionSyntax(value)) {
            fieldModes.value[fieldKey] = 'expression';
        }
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

    const stepExecutionsForStep = computed(() => {
        if (!props.node || !props.stepExecutions) return [];
        return props.stepExecutions
            .filter(se => se.step_id === props.node?.id)
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

    const selectedItemIndex = ref<number | null>(null);

    watch(
        () => props.node?.id,
        () => {
            selectedItemIndex.value = null;
        }
    );

    const activeStepExecution = computed(() => {
        const executions = stepExecutionsForStep.value;
        if (executions.length === 0) return null;

        if (isMultiItemStep.value && selectedItemIndex.value !== null) {
            return executions.find(e => e.item_index === selectedItemIndex.value) || executions[0];
        }

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

    const subnodeSlots = computed<StepSubnodeSlot[]>(() => {
        if (props.stepType?.subnode_slots?.length) return props.stepType.subnode_slots;
        return props.node?.data?.subnode_slots ?? [];
    });

    const incomingConnectionsByTargetInputForStep = computed<Record<string, string[]>>(() => {
        if (!props.node) return {};
        return props.incomingConnectionsByTargetInput?.[props.node.id] ?? {};
    });

    const subnodeSlotRows = computed(() => {
        return subnodeSlots.value.map(slot => {
            const slotId = slot.id;
            const sourceStepIds = incomingConnectionsByTargetInputForStep.value[slotId] ?? [];
            const sourceStepNames = sourceStepIds.map(stepId => props.stepNameById?.[stepId] || stepId);

            return {
                slot,
                sourceStepIds,
                sourceStepNames,
                isConnected: sourceStepIds.length > 0,
            };
        });
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

    const previewIsError = (value: unknown): value is ErrorPayload => {
        if (!value || typeof value !== 'object') return false;
        const payload = value as Record<string, unknown>;
        return payload.type === 'parse_error' || payload.type === 'render_error';
    };

    const previewToText = (value: unknown) => {
        if (value === null) return 'null';
        if (value === undefined) return 'undefined';
        if (typeof value === 'string') return value;
        if (typeof value === 'number' || typeof value === 'boolean') return String(value);

        try {
            return JSON.stringify(value, null, 2);
        } catch {
            return String(value);
        }
    };

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
            return `${baseUrl}/api/hook-test/${path}`;
        } else {
            return `${baseUrl}/api/hooks/${path}`;
        }
    });

    const copyWebhookUrl = () => {
        navigator.clipboard.writeText(webhookUrl.value);
    };

    const slugify = (text: string) => {
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

    return {
        activeTab,
        fieldModes,
        fieldValues,
        searchQuery,
        isEditingName,
        editName,
        canEdit,
        originalValues,
        originalName,
        showCloseConfirmation,
        hasUnsavedChanges,
        closeModal,
        confirmClose,
        cancelClose,
        saveConfig,
        setFieldMode,
        fields,
        fieldByKey,
        fieldSupportsExpression,
        handleFieldValueUpdate,
        expandedSections,
        toggleSection,
        stepExecutionsForStep,
        isMultiItemStep,
        itemStats,
        selectedItemIndex,
        activeStepExecution,
        pinnedOutputs,
        hasPinnedOutput,
        pinnedOutput,
        canPinOutput,
        pinButtonLabel,
        pinOutput,
        unpinOutput,
        toRecord,
        evaluatedConfig,
        isTriggerStep,
        directUpstreamStepIds,
        inputIndexLabels,
        subnodeSlots,
        incomingConnectionsByTargetInputForStep,
        subnodeSlotRows,
        currentInputState,
        currentInputEmptyState,
        runInputLabel,
        runInput,
        contextData,
        explorerData,
        previewKeyFor,
        hasPreviewFor,
        previewValueFor,
        previewIsError,
        previewToText,
        webhookMode,
        isWebhookTrigger,
        webhookPath,
        webhookMethod,
        webhookTestState,
        isWebhookListening,
        isWebhookListeningElsewhere,
        webhookUrl,
        copyWebhookUrl,
        slugify,
        getExpressionFor,
        copyExpression,
        formatSectionKey,
        toggleWebhookListening,
    };
}
