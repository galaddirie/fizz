import { readStorageString } from './storage';

export type ThemePreference = 'system' | 'light' | 'dark';
export type ResolvedTheme = 'light' | 'dark';

export const THEME_STORAGE_KEY = 'theme';
export const THEME_PREFERENCES: ThemePreference[] = ['system', 'light', 'dark'];

export const isThemePreference = (value: string | null | undefined): value is ThemePreference =>
  value === 'system' || value === 'light' || value === 'dark';

export const getSystemThemeMediaQuery = () => {
  if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') {
    return null;
  }

  return window.matchMedia('(prefers-color-scheme: dark)');
};

export const resolveSystemTheme = (): ResolvedTheme => {
  const mediaQuery = getSystemThemeMediaQuery();
  return mediaQuery?.matches ? 'dark' : 'light';
};

export const resolveThemePreference = (preference: ThemePreference): ResolvedTheme =>
  preference === 'system' ? resolveSystemTheme() : preference;

export const readStoredThemePreference = (): ThemePreference => {
  const stored = readStorageString(THEME_STORAGE_KEY);
  return isThemePreference(stored) ? stored : 'system';
};

export const applyResolvedTheme = (theme: ResolvedTheme) => {
  if (typeof document === 'undefined') return;
  document.documentElement.setAttribute('data-theme', theme);
};

