import { ref, watch } from 'vue';
import { defineStore } from 'pinia';

export const useThemeStore = defineStore('theme', () => {
  // Get initial theme from localStorage or follow system preference
  const savedTheme = localStorage.getItem('theme');

  // Determine initial theme
  const getInitialTheme = () => {
    if (savedTheme && ['light', 'dark'].includes(savedTheme)) {
      return savedTheme;
    }
    // Follow system preference
    return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
  };

  const theme = ref(getInitialTheme());

  // Available themes including system
  const themes = ['system', 'light', 'dark'];

  // Set theme function
  function setTheme(newTheme: string) {
    if (newTheme === 'system') {
      localStorage.removeItem('theme');
      // Follow system preference
      const isDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
      theme.value = isDark ? 'dark' : 'light';
      document.documentElement.setAttribute('data-theme', theme.value);
    } else if (['light', 'dark'].includes(newTheme)) {
      theme.value = newTheme;
      localStorage.setItem('theme', newTheme);
      document.documentElement.setAttribute('data-theme', newTheme);
    }
  }

  // Toggle between light and dark (only manual themes)
  function toggleTheme() {
    const newTheme = theme.value === 'light' ? 'dark' : 'light';
    setTheme(newTheme);
  }

  // Initialize theme on app start
  document.documentElement.setAttribute('data-theme', theme.value);

  // Watch for system theme changes
  const mediaQuery = window.matchMedia('(prefers-color-scheme: dark)');
  watch(
    () => mediaQuery.matches,
    isDark => {
      // Only auto-switch if following system preference (no manual theme set)
      if (!localStorage.getItem('theme')) {
        theme.value = isDark ? 'dark' : 'light';
        document.documentElement.setAttribute('data-theme', theme.value);
      }
    },
    { immediate: true }
  );

  return {
    theme,
    themes,
    setTheme,
    toggleTheme,
    isSystemTheme: () => !localStorage.getItem('theme'),
  };
});
