import type { StepInputHandle, StepOutputHandle, StepType } from '@/types/workflow';

const DEFAULT_HANDLE = 'main';

const asRecord = (value: unknown): Record<string, unknown> =>
  value && typeof value === 'object' && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {};

const asStringArray = (value: unknown): string[] =>
  Array.isArray(value) ? value.filter((item): item is string => typeof item === 'string') : [];

const handleKind = (value: unknown): 'flow' | 'dependency' =>
  value === 'dependency' ? 'dependency' : 'flow';

const cardinality = (value: unknown): 'one' | 'many' => (value === 'many' ? 'many' : 'one');

export const inputHandlesFromSchema = (schema: unknown): StepInputHandle[] => {
  const inputSchema = asRecord(schema);
  const properties = asRecord(inputSchema.properties);
  const required = new Set(asStringArray(inputSchema.required));

  const handles = Object.entries(properties).flatMap(([key, value]) => {
    const property = asRecord(value);
    const connection =
      property.connection && typeof property.connection === 'object'
        ? asRecord(property.connection)
        : key === DEFAULT_HANDLE
          ? { kind: 'flow' }
          : null;

    if (!connection) return [];

    const accepts = asRecord(connection.accepts);

    return [
      {
        id: typeof connection.handle === 'string' ? connection.handle : key,
        key,
        title: typeof property.title === 'string' ? property.title : undefined,
        description: typeof property.description === 'string' ? property.description : undefined,
        kind: handleKind(connection.kind),
        cardinality: cardinality(connection.cardinality),
        required: required.has(key),
        accepts: {
          provides: asStringArray(accepts.provides),
        },
      } satisfies StepInputHandle,
    ];
  });

  if (handles.some(handle => handle.id === DEFAULT_HANDLE)) return handles;

  return [
    {
      id: DEFAULT_HANDLE,
      key: DEFAULT_HANDLE,
      title: 'Input',
      kind: 'flow',
      cardinality: 'one',
      required: false,
      accepts: { provides: [] },
    },
    ...handles,
  ];
};

export const outputHandlesFromSchema = (schema: unknown): StepOutputHandle[] => {
  const outputSchema = asRecord(schema);
  const topLevelProvides = asStringArray(outputSchema.provides);
  const outputs = Array.isArray(outputSchema.outputs) ? outputSchema.outputs : null;

  if (!outputs) {
    return [{ id: DEFAULT_HANDLE, kind: 'flow', provides: topLevelProvides }];
  }

  return outputs.flatMap(output => {
    const spec = asRecord(output);
    const provides = asStringArray(spec.provides).length
      ? asStringArray(spec.provides)
      : topLevelProvides;

    if (typeof spec.id !== 'string' || spec.id.length === 0) return [];

    return [
      {
        id: spec.id,
        kind: handleKind(spec.kind),
        provides,
      } satisfies StepOutputHandle,
    ];
  });
};

export const dependencyInputHandles = (stepType?: StepType | null): StepInputHandle[] => {
  if (!stepType) return [];
  return inputHandlesFromSchema(stepType.input_schema).filter(handle => handle.kind === 'dependency');
};

export const isDependencyTargetHandle = (
  stepType: StepType | undefined | null,
  handleId: string | null | undefined
) => {
  const id = handleId || DEFAULT_HANDLE;
  return dependencyInputHandles(stepType).some(handle => handle.id === id);
};

export const stepTypeProvides = (
  stepType?: Pick<StepType, 'output_schema'> | null
): string[] => {
  if (!stepType) return [];

  return outputHandlesFromSchema(stepType.output_schema).flatMap(handle => handle.provides);
};
