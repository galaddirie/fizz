<script setup lang="ts">
import { Link } from 'live_vue';
import { ArrowPathIcon, ListBulletIcon, PlayIcon } from '@heroicons/vue/24/outline';

interface Props {
  isExecutionFailed: boolean;
  isExecutionRunning: boolean;
  isPreviewActive: boolean;
  workflowExecutionsLink?: string | null;
}

defineProps<Props>();

const emit = defineEmits<{
  (e: 'run'): void;
  (e: 'cancel'): void;
}>();
</script>

<template>
  <div>
    <div
      v-if="isExecutionFailed"
      class="pointer-events-none absolute inset-0 z-40 opacity-100 transition-opacity duration-1000 ease-out"
      style="
        background: radial-gradient(
          ellipse at center,
          transparent 70%,
          rgba(239, 68, 68, 0.04) 90%,
          rgba(239, 68, 68, 0.06) 100%
        );
      "
    ></div>

    <div
      v-if="!isPreviewActive"
      class="pointer-events-auto absolute bottom-16 left-1/2 z-[1100] flex -translate-x-1/2 items-center gap-3 transform transition-all duration-300 ease-in-out"
    >
      <button
        v-if="!isExecutionRunning"
        class="btn btn-primary shadow-primary/20 flex items-center gap-3 rounded-xl px-8 py-3 text-base font-semibold shadow-lg transition-all hover:scale-105 active:scale-95"
        @click="emit('run')"
      >
        <PlayIcon class="h-6 w-6" />
        <span class="text-base font-semibold">Execute Workflow</span>
      </button>
      <button
        v-else
        class="btn btn-warning shadow-warning/20 flex items-center gap-3 rounded-xl px-8 py-3 text-base font-semibold shadow-lg transition-all hover:scale-105 active:scale-95"
        @click="emit('cancel')"
      >
        <ArrowPathIcon class="h-6 w-6 animate-spin" />
        <span class="text-base font-semibold">Stop Execution</span>
      </button>

      <div
        v-if="workflowExecutionsLink"
        class="tooltip tooltip-top"
        data-tip="View execution history"
      >
        <Link
          :navigate="workflowExecutionsLink"
          class="btn btn-circle btn-outline border-base-300/80 bg-base-100/95 text-base-content/70 shadow-lg backdrop-blur-sm transition-all hover:scale-105 hover:bg-base-100 hover:text-base-content"
          aria-label="View execution history"
        >
          <ListBulletIcon class="h-5 w-5" />
        </Link>
      </div>
    </div>
  </div>
</template>
