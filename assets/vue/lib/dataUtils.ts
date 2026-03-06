export function unwrapData(data: unknown): unknown {
  if (data === null || data === undefined) return data;

  if (Array.isArray(data)) {
    const unwrapped = data
      .map(unwrapData)
      .filter((i) => i !== null && i !== undefined);
    if (unwrapped.length === 1) {
      return unwrapped[0];
    }
    return unwrapped;
  }

  if (typeof data === "object" && data !== null && !Array.isArray(data)) {
    const record = data as Record<string, unknown>;
    if (Object.keys(record).length === 1 && "value" in record) {
      return unwrapData(record.value);
    }
  }

  return data;
}

export function toRecord(value: unknown): Record<string, unknown> | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  return value as Record<string, unknown>;
}

export function formatDataForDisplay(data: unknown): string {
  const unwrapped = unwrapData(data);
  if (unwrapped === null || unwrapped === undefined) return "null";
  if (typeof unwrapped === "string") return unwrapped;
  return JSON.stringify(unwrapped, null, 2);
}
