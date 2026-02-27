<script setup lang="ts">
import { computed } from 'vue';
import ThemeSelector from '@/ThemeSelector.vue';
import Avatar from '@/components/ui/Avatar.vue';
import type { UserPresence } from '@/types/workflow';
import {
  BoltIcon,
  ArrowUturnLeftIcon,
  ArrowUturnRightIcon,
  CloudArrowUpIcon,
  ExclamationCircleIcon,
  ArrowPathIcon,
  ClockIcon,
  RocketLaunchIcon,
} from '@heroicons/vue/24/outline';

// =============================================================================
// Props
// =============================================================================

interface Props {
  isSaving?: boolean;
  canUndo?: boolean;
  canRedo?: boolean;
  undoTooltip?: string;
  redoTooltip?: string;
  isUndoPending?: boolean;
  presences?: UserPresence[];
  validationErrors?: string[];
}

const props = withDefaults(defineProps<Props>(), {
  isSaving: false,
  canUndo: false,
  canRedo: false,
  undoTooltip: 'Undo (⌘Z)',
  redoTooltip: 'Redo (⌘⇧Z)',
  isUndoPending: false,
  presences: () => [],
  validationErrors: () => [],
});

// =============================================================================
// Emits
// =============================================================================

const emit = defineEmits<{
  (e: 'save'): void;
  (e: 'undo'): void;
  (e: 'redo'): void;
  (e: 'run-test'): void;
  (e: 'publish'): void;
  (e: 'rename', name: string): void;
  (e: 'open-revisions'): void;
}>();

// =============================================================================
// Computed
// =============================================================================


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

    <header class="pointer-events-auto bg-base-100 relative flex h-full items-center gap-4 rounded-bl-[20px] border-b border-l border-base-300 pl-4 pr-6 pb-3.5">
      <!-- Border Mask for seamless curve transition -->
      <div class="absolute -left-[1.5px] top-0 h-[20px] w-[3px] bg-base-100 rounded-full"></div>
    <!-- Center Section: Undo/Redo Tools -->
    <div class="bg-base-200/50 border-base-300/30 flex items-center gap-1 rounded-2xl border p-1.5">
      <button
        class="btn btn-ghost btn-xs btn-square tooltip tooltip-bottom hover:bg-base-100 rounded-lg disabled:opacity-30"
        :disabled="!canUndo || isUndoPending"
        :data-tip="undoTooltip"
        @click="emit('undo')"
      >
        <ArrowPathIcon v-if="isUndoPending" class="h-4 w-4 animate-spin" />
        <ArrowUturnLeftIcon v-else class="h-4.5 w-4.5" />
      </button>
      <button
        class="btn btn-ghost btn-xs btn-square tooltip tooltip-bottom hover:bg-base-100 rounded-lg disabled:opacity-30"
        :disabled="!canRedo || isUndoPending"
        :data-tip="redoTooltip"
        @click="emit('redo')"
      >
        <ArrowPathIcon v-if="isUndoPending" class="h-4 w-4 animate-spin" />
        <ArrowUturnRightIcon v-else class="h-4.5 w-4.5" />
      </button>
    </div>

    <!-- Right Section: Collaboration + Actions -->
    <div class="flex items-center gap-4">
      <!-- Collaborators -->
      <!-- <Avatar :presences="presences" /> -->

      <!-- Validation Errors Indicator -->
      <div
        v-if="hasErrors"
        class="tooltip tooltip-bottom"
        :data-tip="`${validationErrors.length} validation error(s)`"
      >
        <button class="btn btn-ghost btn-sm btn-circle text-error">
          <ExclamationCircleIcon class="h-5 w-5" />
        </button>
      </div>



      <button
        class="btn btn-sm btn-ghost border-base-300 bg-base-100 hover:bg-base-200 text-base-content/70 flex gap-2 rounded-xl border px-4 text-sm font-semibold transition-all"
        @click="emit('open-revisions')"
      >
        <ClockIcon class="h-5 w-5" />
      </button>

      <!-- Save Button -->
      <button
        class="btn btn-sm btn-ghost border-base-300 bg-base-100 hover:bg-base-200 text-base-content/70 flex gap-2 rounded-xl border px-5 text-sm font-semibold transition-all"
        :disabled="isSaving"
        @click="emit('save')"
      >
        <span v-if="isSaving" class="loading loading-spinner loading-xs text-primary"></span>
        <CloudArrowUpIcon v-else class="h-5 w-5" />
        {{ isSaving ? 'Saving...' : 'Save' }}
      </button>

      <!-- Publish Button -->
      <button
        class="btn btn-sm btn-primary text-primary-content flex gap-2 rounded-xl px-5 text-sm font-semibold shadow-md transition-all hover:shadow-lg"
        @click="emit('publish')"
      >
        <RocketLaunchIcon class="h-5 w-5" />
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
