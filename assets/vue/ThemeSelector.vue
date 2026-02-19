<template>
  <div
    class="card border-base-300 bg-base-300 relative flex w-fit flex-row items-center rounded-full border-2"
  >
    <!-- Sliding background -->
    <div
      class="border-base-200 bg-base-100 absolute h-full w-1/3 rounded-full border brightness-200 transition-[left] duration-300 ease-in-out"
      :class="sliderPosition"
    />

    <!-- System theme button -->
    <button
      @click="setTheme('system')"
      class="relative z-10 flex h-8 w-8 cursor-pointer p-2"
      :class="{ 'text-primary': themeStore.isSystemTheme() }"
    >
      <ComputerDesktopIcon class="size-5 opacity-75 hover:opacity-100" />
    </button>

    <!-- Light theme button -->
    <button
      @click="setTheme('light')"
      class="relative z-10 flex h-8 w-8 cursor-pointer p-2"
      :class="{ 'text-primary': themeStore.theme === 'light' && !themeStore.isSystemTheme() }"
    >
      <SunIcon class="size-5 opacity-75 hover:opacity-100" />
    </button>

    <!-- Dark theme button -->
    <button
      @click="setTheme('dark')"
      class="relative z-10 flex h-8 w-8 cursor-pointer p-2"
      :class="{ 'text-primary': themeStore.theme === 'dark' }"
    >
      <MoonIcon class="size-5 opacity-75 hover:opacity-100" />
    </button>
  </div>
</template>

<script setup lang="ts">
import { computed } from 'vue';
import { useThemeStore } from '@/stores/theme';
import { ComputerDesktopIcon, SunIcon, MoonIcon } from '@heroicons/vue/24/outline';

const themeStore = useThemeStore();

const sliderPosition = computed(() => {
  if (themeStore.isSystemTheme()) {
    return 'left-0';
  } else if (themeStore.theme === 'light') {
    return 'left-1/3';
  } else if (themeStore.theme === 'dark') {
    return 'left-2/3';
  }
  return 'left-0';
});

const setTheme = (theme: 'system' | 'light' | 'dark') => {
  if (theme === 'system') {
    // Remove manual theme preference to follow system
    localStorage.removeItem('theme');
    const isDark = window.matchMedia('(prefers-color-scheme: dark)').matches;
    themeStore.setTheme(isDark ? 'dark' : 'light');
  } else {
    themeStore.setTheme(theme);
  }
};

// Add keyboard shortcut for theme toggle
document.addEventListener('keydown', e => {
  if (e.key === 't' && (e.ctrlKey || e.metaKey)) {
    e.preventDefault();
    themeStore.toggleTheme();
  }
});
</script>
