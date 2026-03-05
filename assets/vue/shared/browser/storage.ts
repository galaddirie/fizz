const canUseStorage = () =>
  typeof window !== 'undefined' && typeof window.localStorage !== 'undefined';

export const readStorageString = (key: string): string | null => {
  if (!canUseStorage()) return null;

  try {
    return window.localStorage.getItem(key);
  } catch {
    return null;
  }
};

export const writeStorageString = (key: string, value: string) => {
  if (!canUseStorage()) return;

  try {
    window.localStorage.setItem(key, value);
  } catch {
    // Ignore storage failures in restricted/private browsing contexts.
  }
};

export const removeStorageItem = (key: string) => {
  if (!canUseStorage()) return;

  try {
    window.localStorage.removeItem(key);
  } catch {
    // Ignore storage failures in restricted/private browsing contexts.
  }
};

export const readStorageBoolean = (key: string, fallback: boolean) => {
  const value = readStorageString(key);
  if (value === null) return fallback;
  return value === '1';
};

export const writeStorageBoolean = (key: string, value: boolean) => {
  writeStorageString(key, value ? '1' : '0');
};

