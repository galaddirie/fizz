import { createPinia } from 'pinia';
import { mount } from '@vue/test-utils';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';

import ThemeSelector from './ThemeSelector.vue';
import { useThemeStore } from '@/app/theme/themeStore';

describe('ThemeSelector', () => {
  const matchMedia = vi.fn().mockReturnValue({
    matches: false,
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
  });

  beforeEach(() => {
    vi.stubGlobal('matchMedia', matchMedia);
    localStorage.clear();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('registers and cleans up the theme hotkey on mount', async () => {
    const pinia = createPinia();
    const store = useThemeStore(pinia);

    store.initialize();
    store.setTheme('light');

    const wrapper = mount(ThemeSelector, {
      global: {
        plugins: [pinia],
      },
    });

    window.dispatchEvent(new KeyboardEvent('keydown', { key: 't', metaKey: true }));
    expect(store.theme).toBe('dark');

    wrapper.unmount();

    window.dispatchEvent(new KeyboardEvent('keydown', { key: 't', metaKey: true }));
    expect(store.theme).toBe('dark');
  });
});

