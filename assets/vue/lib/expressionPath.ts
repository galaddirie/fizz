export function buildStepRootPath(
  stepName?: string | null,
  fallbackKey?: string | null
): string {
  if (typeof stepName === 'string' && stepName.trim().length > 0) {
    return `steps[${JSON.stringify(stepName)}]`;
  }

  if (typeof fallbackKey === 'string' && fallbackKey.trim().length > 0) {
    return `steps[${JSON.stringify(fallbackKey)}]`;
  }

  return 'steps';
}
