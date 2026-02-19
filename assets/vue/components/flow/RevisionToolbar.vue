<script setup lang="ts">
import { ArrowLeftIcon } from '@heroicons/vue/24/outline';

interface Props {
  workflowName: string;
  revisionLabel: string;
  canApply: boolean;
}

withDefaults(defineProps<Props>(), {
  workflowName: 'Untitled Workflow',
  revisionLabel: 'Revision',
  canApply: false,
});

const emit = defineEmits<{
  (e: 'back'): void;
  (e: 'apply'): void;
}>();
</script>

<template>
  <header
    class="bg-base-100/80 border-base-200 z-30 flex h-16 shrink-0 items-center justify-between border-b px-6 shadow-sm backdrop-blur-md"
  >
    <button class="btn btn-ghost btn-sm gap-2" @click="emit('back')">
      <ArrowLeftIcon class="h-4 w-4" />
      Back to Editor
    </button>

    <div class="flex items-center gap-3">
      <span class="text-base-content/80 text-sm font-semibold">{{ workflowName }}</span>
      <span class="badge badge-primary badge-sm font-mono opacity-90">{{ revisionLabel }}</span>
    </div>

    <button class="btn btn-primary btn-sm" :disabled="!canApply" @click="emit('apply')">
      Apply Revision
    </button>
  </header>
</template>
