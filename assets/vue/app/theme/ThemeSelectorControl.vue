<template>
  <div
    class="card border-base-300 bg-base-300 relative flex w-fit flex-row items-center rounded-full border-2"
  >
    <div
      class="border-base-200 bg-base-100 absolute h-full w-1/3 rounded-full border brightness-200 transition-[left] duration-300 ease-in-out"
      :class="sliderPosition"
    />

    <button
      type="button"
      class="relative z-10 flex h-8 w-8 cursor-pointer p-2"
      :class="{ 'text-primary': themeStore.isSystemTheme }"
      aria-label="Use system theme"
      @click="themeStore.setTheme('system')"
    >
      <ComputerDesktopIcon class="size-5 opacity-75 hover:opacity-100" />
    </button>

    <button
      type="button"
      class="relative z-10 flex h-8 w-8 cursor-pointer p-2"
      :class="{ 'text-primary': themeStore.theme === 'light' && !themeStore.isSystemTheme }"
      aria-label="Use light theme"
      @click="themeStore.setTheme('light')"
    >
      <SunIcon class="size-5 opacity-75 hover:opacity-100" />
    </button>

    <button
      type="button"
      class="relative z-10 flex h-8 w-8 cursor-pointer p-2"
      :class="{ 'text-primary': themeStore.theme === 'dark' && !themeStore.isSystemTheme }"
      aria-label="Use dark theme"
      @click="themeStore.setTheme('dark')"
    >
      <MoonIcon class="size-5 opacity-75 hover:opacity-100" />
    </button>
  </div>
</template>

<script setup lang="ts">
import { computed } from 'vue';
import { ComputerDesktopIcon, MoonIcon, SunIcon } from '@heroicons/vue/24/outline';

import { useThemeHotkey } from './useThemeHotkey';
import { useThemeStore } from './themeStore';

const themeStore = useThemeStore();
useThemeHotkey();

const sliderPosition = computed(() => {
  if (themeStore.isSystemTheme) return 'left-0';
  if (themeStore.theme === 'light') return 'left-1/3';
  if (themeStore.theme === 'dark') return 'left-2/3';
  return 'left-0';
});
</script>

