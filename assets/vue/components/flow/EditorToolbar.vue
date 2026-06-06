<script setup lang="ts">
import { computed } from 'vue';
import {
  ArrowUturnLeftIcon,
  ArrowUturnRightIcon,
  ExclamationCircleIcon,
  ArrowPathIcon,
  ClockIcon,
  RocketLaunchIcon,
} from '@heroicons/vue/24/outline';

interface Props {
  canUndo?: boolean;
  canRedo?: boolean;
  undoTooltip?: string;
  redoTooltip?: string;
  isUndoPending?: boolean;
  validationErrors?: string[];
}

const props = withDefaults(defineProps<Props>(), {
  canUndo: false,
  canRedo: false,
  undoTooltip: 'Undo (⌘Z)',
  redoTooltip: 'Redo (⌘⇧Z)',
  isUndoPending: false,
  validationErrors: () => [],
});

const emit = defineEmits<{
  (e: 'undo'): void;
  (e: 'redo'): void;
  (e: 'publish'): void;
  (e: 'open-revisions'): void;
}>();

const hasErrors = computed(() => props.validationErrors.length > 0);
</script>

<template>
  <div class="pointer-events-none relative flex h-[35px] items-start [filter:drop-shadow(0_10px_8px_rgba(0,0,0,0.02))] sm:[filter:drop-shadow(0_4px_3px_rgba(0,0,0,0.03))]">
    <div class="pointer-events-none absolute -left-[20px] top-0 h-[20px] w-[20px] text-base-100">
      <svg class="absolute inset-0 h-full w-full" viewBox="0 0 20 20" fill="none" xmlns="http://www.w3.org/2000/svg">
        <path d="M20 20V0H0C11.0457 0 20 8.9543 20 20Z" fill="currentColor" />
        <path d="M0 0C11.0457 0 20 8.9543 20 20" stroke="var(--fallback-b3,oklch(var(--b3)))" stroke-width="1.5" />
      </svg>
    </div>

    <header class="pointer-events-auto bg-base-100 relative flex h-full items-center gap-2.5 rounded-bl-[20px] border-b border-l-0 border-base-300 pl-4 pr-5 pb-3.5">
      <!-- Undo/Redo -->
      <div class="flex items-center gap-0.5 rounded-lg border border-base-300/40 bg-base-200/40 p-1">
        <button
          class="btn btn-ghost btn-xs btn-square tooltip tooltip-bottom rounded-md transition-colors disabled:opacity-25"
          :disabled="!canUndo || isUndoPending"
          :data-tip="undoTooltip"
          @click="emit('undo')"
        >
          <ArrowPathIcon v-if="isUndoPending" class="h-3.5 w-3.5 animate-spin" />
          <ArrowUturnLeftIcon v-else class="h-4 w-4" />
        </button>
        <button
          class="btn btn-ghost btn-xs btn-square tooltip tooltip-bottom rounded-md transition-colors disabled:opacity-25"
          :disabled="!canRedo || isUndoPending"
          :data-tip="redoTooltip"
          @click="emit('redo')"
        >
          <ArrowPathIcon v-if="isUndoPending" class="h-3.5 w-3.5 animate-spin" />
          <ArrowUturnRightIcon v-else class="h-4 w-4" />
        </button>
      </div>

      <div class="flex items-center gap-2">
        <!-- Validation Errors -->
        <button
          v-if="hasErrors"
          class="btn btn-ghost btn-xs btn-square tooltip tooltip-bottom text-error rounded-md"
          :data-tip="`${validationErrors.length} validation error(s)`"
        >
          <ExclamationCircleIcon class="h-4.5 w-4.5" />
        </button>

        <!-- Revisions -->
        <button
          class="btn btn-ghost btn-xs btn-square tooltip tooltip-bottom rounded-md text-base-content/50 hover:text-base-content/80 transition-colors"
          data-tip="Revisions"
          @click="emit('open-revisions')"
        >
          <ClockIcon class="h-4.5 w-4.5" />
        </button>

        <!-- Publish -->
        <button
          class="btn btn-sm btn-primary text-primary-content flex items-center gap-1.5 rounded-lg px-4 text-xs font-semibold shadow-sm transition-all hover:shadow-md"
          @click="emit('publish')"
        >
          <RocketLaunchIcon class="h-4 w-4" />
          Publish
        </button>
      </div>
    </header>
  </div>
</template>

<style scoped>
.tooltip::before {
  font-size: 11px;
  padding: 4px 8px;
}
</style>
