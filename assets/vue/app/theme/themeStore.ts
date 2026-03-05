import { computed, ref } from 'vue';
import { defineStore } from 'pinia';

import {
  THEME_PREFERENCES,
  THEME_STORAGE_KEY,
  applyResolvedTheme,
  getSystemThemeMediaQuery,
  readStoredThemePreference,
  resolveThemePreference,
  type ResolvedTheme,
  type ThemePreference,
} from '@/shared/browser/mediaTheme';
import { removeStorageItem, writeStorageString } from '@/shared/browser/storage';

type MediaListener = (event: MediaQueryListEvent) => void;
type LegacyMediaQueryList = MediaQueryList & {
  addListener: (listener: MediaListener) => void;
  removeListener: (listener: MediaListener) => void;
};

const addMediaListener = (mediaQuery: MediaQueryList, listener: MediaListener) => {
  if ('addEventListener' in mediaQuery) {
    mediaQuery.addEventListener('change', listener);
    return;
  }

  (mediaQuery as LegacyMediaQueryList).addListener(listener);
};

const removeMediaListener = (mediaQuery: MediaQueryList, listener: MediaListener) => {
  if ('removeEventListener' in mediaQuery) {
    mediaQuery.removeEventListener('change', listener);
    return;
  }

  (mediaQuery as LegacyMediaQueryList).removeListener(listener);
};

export const useThemeStore = defineStore('theme', () => {
  const preference = ref<ThemePreference>('system');
  const theme = ref<ResolvedTheme>('light');
  const initialized = ref(false);

  let mediaQuery: MediaQueryList | null = null;
  let mediaListener: MediaListener | null = null;

  const syncResolvedTheme = () => {
    theme.value = resolveThemePreference(preference.value);
    applyResolvedTheme(theme.value);
  };

  const cleanup = () => {
    if (mediaQuery && mediaListener) {
      removeMediaListener(mediaQuery, mediaListener);
    }

    mediaQuery = null;
    mediaListener = null;
    initialized.value = false;
  };

  const initialize = () => {
    if (initialized.value) {
      applyResolvedTheme(theme.value);
      return;
    }

    preference.value = readStoredThemePreference();
    syncResolvedTheme();

    mediaQuery = getSystemThemeMediaQuery();
    mediaListener = event => {
      if (preference.value !== 'system') return;

      theme.value = event.matches ? 'dark' : 'light';
      applyResolvedTheme(theme.value);
    };

    if (mediaQuery) {
      addMediaListener(mediaQuery, mediaListener);
    }

    initialized.value = true;
  };

  const setTheme = (nextPreference: ThemePreference) => {
    preference.value = nextPreference;

    if (nextPreference === 'system') {
      removeStorageItem(THEME_STORAGE_KEY);
    } else {
      writeStorageString(THEME_STORAGE_KEY, nextPreference);
    }

    syncResolvedTheme();
  };

  const toggleTheme = () => {
    setTheme(theme.value === 'light' ? 'dark' : 'light');
  };

  return {
    theme,
    preference,
    themes: THEME_PREFERENCES,
    initialized,
    initialize,
    cleanup,
    setTheme,
    toggleTheme,
    isSystemTheme: computed(() => preference.value === 'system'),
  };
});
