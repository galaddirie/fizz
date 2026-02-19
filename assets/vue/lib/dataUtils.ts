/**
 * Handles the "wrapped" data structure from the backend.
 * Values are often wrapped as { "value": ... } to preserve types in DB/JSON.
 */
export function unwrapData(data: unknown): unknown {
  if (data === null || data === undefined) return data;

  // Handle Join Coalescing (lists with nulls)
  if (Array.isArray(data)) {
    const unwrapped = data.map(unwrapData).filter(i => i !== null && i !== undefined);
    if (unwrapped.length === 1) {
      return unwrapped[0];
    }
    return unwrapped;
  }

  if (typeof data === 'object' && data !== null && !Array.isArray(data)) {
    const record = data as Record<string, unknown>;
    if (Object.keys(record).length === 1 && 'value' in record) {
      return unwrapData(record.value);
    }
  }

  return data;
}

/**
 * Formats data for display, ensuring it's unwrapped first.
 */
export function formatDataForDisplay(data: unknown): string {
  const unwrapped = unwrapData(data);
  if (unwrapped === null || unwrapped === undefined) return 'null';
  if (typeof unwrapped === 'string') return unwrapped;
  return JSON.stringify(unwrapped, null, 2);
}
