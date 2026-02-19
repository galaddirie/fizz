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
  workflowName?: string;
  workflowStatus?: 'draft' | 'active' | 'archived';
  lastSaved?: string;
  isSaving?: boolean;
  hasUnsavedChanges?: boolean;
  canUndo?: boolean;
  canRedo?: boolean;
  undoTooltip?: string;
  redoTooltip?: string;
  isUndoPending?: boolean;
  presences?: UserPresence[];
  validationErrors?: string[];
}

const props = withDefaults(defineProps<Props>(), {
  workflowName: 'Untitled Workflow',
  workflowStatus: 'draft',
  lastSaved: 'Just now',
  isSaving: false,
  hasUnsavedChanges: false,
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

const statusBadge = computed(() => {
  const configs = {
    draft: { class: 'badge-warning', label: 'Draft' },
    active: { class: 'badge-success', label: 'Active' },
    archived: { class: 'badge-ghost', label: 'Archived' },
  };
  return configs[props.workflowStatus];
});

const hasErrors = computed(() => props.validationErrors.length > 0);
</script>

<template>
  <header
    class="bg-base-100/80 border-base-200 z-30 flex h-16 shrink-0 items-center justify-between border-b px-6 shadow-sm backdrop-blur-md"
  >
    <!-- Left Section: Logo & Title -->
    <div class="flex items-center gap-5">
      <!-- Logo -->
      <div
        class="bg-primary/10 text-primary flex h-11 w-11 items-center justify-center rounded-2xl shadow-inner"
      >
        <BoltIcon class="h-7 w-7" />
      </div>

      <!-- Workflow Info -->
      <div>
        <div class="flex items-center gap-2.5">
          <h1 class="text-base-content/90 text-sm font-semibold">
            {{ workflowName }}
          </h1>
          <span :class="['badge badge-sm h-5 gap-1.5 font-bold opacity-80', statusBadge.class]">
            <span class="h-1 w-1 rounded-full bg-current"></span>
            {{ statusBadge.label }}
          </span>

          <!-- Unsaved indicator -->
          <span v-if="hasUnsavedChanges" class="badge badge-ghost badge-xs"> Unsaved </span>
        </div>

        <p class="text-base-content/40 mt-0.5 text-xs font-semibold tracking-tight">
          <span v-if="isSaving" class="flex items-center gap-1">
            <ArrowPathIcon class="h-3 w-3 animate-spin" />
            Saving...
          </span>
          <span v-else> Last saved: {{ lastSaved }} </span>
        </p>
      </div>
    </div>

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
      <Avatar :presences="presences" />

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

      <!-- Theme Selector -->
      <div class="bg-base-200/50 border-base-300/30 rounded-full border p-1">
        <ThemeSelector />
      </div>

      <button
        class="btn btn-sm btn-ghost border-base-300 bg-base-100 hover:bg-base-200 text-base-content/70 flex gap-2 rounded-xl border px-4 text-sm font-semibold transition-all"
        @click="emit('open-revisions')"
      >
        <ClockIcon class="h-5 w-5" />
        Revisions
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
</template>

<style scoped>
.tooltip::before {
  font-size: 11px;
  padding: 4px 8px;
}
</style>
