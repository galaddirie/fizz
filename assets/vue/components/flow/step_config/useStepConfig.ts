import { ref, computed, watch, toRaw, type InjectionKey } from "vue";
import { watchDebounced } from "@vueuse/core";
import type { Node } from "@vue-flow/core";
import type {
  EditorState,
  Execution,
  StepExecution,
  StepType,
} from "@/types/workflow";
import type { StepNodeData } from "@/shared/ui/workflow-scene/types";
import type {
  ConfigSchemaField,
  ConfigField,
  ExtendedFieldType,
} from "@/types/configSchema";
import { toRecord } from "@/lib/dataUtils";
import type { StepConfigEmit } from "./contracts";

import { useExpressionPreviews } from "./useExpressionPreviews";
import { useSubnodes } from "./useSubnodes";
import { useStepExecution } from "./useStepExecution";
import { usePinnedOutputs } from "./usePinnedOutputs";
import { useInputData } from "./useInputData";
import { useExpressionHelpers } from "./useExpressionHelpers";
import { useContextExplorer } from "./useContextExplorer";

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

const cloneValue = <T>(value: T): T => {
  const rawValue = toRaw(value);

  if (typeof structuredClone === "function") {
    try {
      return structuredClone(rawValue);
    } catch {
      // Fall through to JSON cloning for values that still cannot be cloned directly.
    }
  }

  return JSON.parse(JSON.stringify(rawValue)) as T;
};

const valuesEqual = (left: unknown, right: unknown): boolean => {
  if (left === right) return true;
  if (Number.isNaN(left) && Number.isNaN(right)) return true;
  if (typeof left !== typeof right) return false;

  if (Array.isArray(left) && Array.isArray(right)) {
    return (
      left.length === right.length &&
      left.every((value, index) => valuesEqual(value, right[index]))
    );
  }

  if (left && right && typeof left === "object" && typeof right === "object") {
    const leftRecord = left as Record<string, unknown>;
    const rightRecord = right as Record<string, unknown>;
    const leftKeys = Object.keys(leftRecord);
    const rightKeys = Object.keys(rightRecord);

    return (
      leftKeys.length === rightKeys.length &&
      leftKeys.every((key) => valuesEqual(leftRecord[key], rightRecord[key]))
    );
  }

  return false;
};

export function useStepConfig(props: UseStepConfigProps, emit: StepConfigEmit) {
  // --- Core state ---
  const fieldModes = ref<Record<string, "literal" | "expression">>({});
  const fieldValues = ref<Record<string, unknown>>({});
  const isEditingName = ref(false);
  const editName = ref("");
  const canEdit = computed(() => props.canEdit ?? true);

  // --- Unsaved changes tracking ---
  const originalValues = ref<Record<string, unknown>>({});
  const originalName = ref("");
  const showCloseConfirmation = ref(false);

  const hasUnsavedChanges = computed(() => {
    if (!canEdit.value) return false;
    if (editName.value !== originalName.value) return true;

    const currentKeys = Object.keys(fieldValues.value);
    const originalKeys = Object.keys(originalValues.value);
    if (currentKeys.length !== originalKeys.length) return true;

    for (const key of currentKeys) {
      if (!valuesEqual(fieldValues.value[key], originalValues.value[key])) {
        return true;
      }
    }
    return false;
  });

  // --- Init watcher: populate fields/modes on open ---
  watch(
    [() => props.node, () => props.isOpen],
    ([newNode, open]) => {
      if (open && newNode && newNode.data) {
        const config = newNode.data.config || {};
        const schema = props.stepType?.config_schema?.properties ?? {};
        const allKeys = new Set([
          ...Object.keys(schema),
          ...Object.keys(config),
        ]);
        const modes: Record<string, "literal" | "expression"> = {};
        const values: Record<string, unknown> = {};

        allKeys.forEach((key) => {
          const schemaField: ConfigSchemaField = schema[key] ?? {};
          const rawValue = config[key] ?? schemaField.default;
          const isSearchField = schemaField.ui?.component === "search";
          const isExpr =
            !isSearchField &&
            typeof rawValue === "string" &&
            (rawValue.includes("{{") || rawValue.includes("{%"));

          modes[key] = isExpr ? "expression" : "literal";
          values[key] = rawValue ?? null;
        });

        fieldModes.value = modes;
        fieldValues.value = values;
        editName.value = newNode.data.name || "";
        isEditingName.value = false;

        originalValues.value = cloneValue(values);
        originalName.value = editName.value;
        showCloseConfirmation.value = false;
      }
    },
    { immediate: true }
  );

  const hasExpressionSyntax = (value: unknown) =>
    typeof value === "string" && (value.includes("{{") || value.includes("{%"));

  // --- Expression preview debounce watcher ---
  watchDebounced(
    [fieldValues, fieldModes],
    () => {
      if (!canEdit.value) return;
      if (!props.isOpen || !props.node) return;

      Object.entries(fieldValues.value).forEach(([key, value]) => {
        if (
          fieldModes.value[key] === "expression" &&
          typeof value === "string" &&
          props.node
        ) {
          emit("preview_expression", {
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
      emit("close");
    }
  };

  const confirmClose = () => {
    showCloseConfirmation.value = false;
    emit("close");
  };

  const cancelClose = () => {
    showCloseConfirmation.value = false;
  };

  const saveConfig = () => {
    if (!canEdit.value) {
      closeModal();
      return;
    }
    if (!props.node) return;
    emit("save", {
      id: props.node.id,
      name: editName.value,
      config: { ...fieldValues.value },
    });

    originalValues.value = cloneValue(fieldValues.value);
    originalName.value = editName.value;
    emit("close");
  };

  // --- Field management ---
  const setFieldMode = (field: string, mode: "literal" | "expression") => {
    if (!canEdit.value) return;
    fieldModes.value[field] = mode;
  };

  const fields = computed<ConfigField[]>(() => {
    if (!props.node || !props.node.data) return [];

    const schema = props.stepType?.config_schema?.properties ?? {};
    const config = props.node.data.config || {};
    const allKeys = new Set([...Object.keys(schema), ...Object.keys(config)]);

    return Array.from(allKeys).map((key) => {
      const schemaField: ConfigSchemaField = schema[key] ?? {};
      const uiComponent = schemaField.ui?.component;
      const format = schemaField.format;
      const typeStr = schemaField.type;

      let inferredType = "text";
      if (uiComponent === "search") inferredType = "search";
      else if (uiComponent === "select") inferredType = "select";
      else if (schemaField.enum && schemaField.enum.length > 0)
        inferredType = "select";
      else if (format === "json") inferredType = "json";
      else if (typeStr === "string" && format === "textarea")
        inferredType = "textarea";
      else if (typeStr === "number" || typeStr === "integer")
        inferredType = "number";
      else if (typeStr === "boolean") inferredType = "boolean";

      return {
        ...schemaField,
        key,
        label:
          schemaField.title ||
          key.replace(/_/g, " ").replace(/\b\w/g, (l) => l.toUpperCase()),
        description: schemaField.description,
        type: inferredType as ExtendedFieldType,
        expressionCapable: true,
      };
    });
  });

  const fieldByKey = computed(() => {
    return fields.value.reduce<Record<string, ConfigField>>((acc, field) => {
      acc[field.key] = field;
      return acc;
    }, {});
  });

  const handleFieldValueUpdate = (fieldKey: string, value: unknown) => {
    fieldValues.value[fieldKey] = value;
    const field = fieldByKey.value[fieldKey];
    const isSearchField = field?.ui?.component === "search";
    if (!isSearchField && hasExpressionSyntax(value)) {
      fieldModes.value[fieldKey] = "expression";
    }
  };

  const nodeId = computed(() => props.node?.id ?? "");

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
    incomingConnectionsByTargetInput: () =>
      props.incomingConnectionsByTargetInput,
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
    handleFieldValueUpdate,
    nodeId,
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
export const StepConfigKey: InjectionKey<StepConfigState> =
  Symbol("StepConfig");
