import { useWindowEvent } from '@/shared/browser/useWindowEvent';

import { useThemeStore } from './themeStore';

export function useThemeHotkey() {
  const themeStore = useThemeStore();

  const handleKeydown = (event: KeyboardEvent) => {
    if (event.key.toLowerCase() !== 't') return;
    if (!event.metaKey && !event.ctrlKey) return;

    event.preventDefault();
    themeStore.toggleTheme();
  };

  useWindowEvent('keydown', handleKeydown);
}

