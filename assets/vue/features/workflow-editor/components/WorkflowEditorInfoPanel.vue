<script setup lang="ts">
import { BugAntIcon, SlashIcon } from '@heroicons/vue/24/outline';

import Avatar from '@/components/ui/Avatar.vue';
import type { UserPresence } from '@/types/workflow';

interface Props {
  workspaceLink?: string | null;
  workspaceName?: string;
  workflowName: string;
  presences: UserPresence[];
  lastSaved: string;
  lastSavedExact: string;
  isDebugMode: boolean;
  debugStatusBadge: {
    dotClass: string;
    label: string;
  };
  debugExecutionShortId: string;
  debugExecutionTimestamp?: string | null;
  debugExecutionLink?: string | null;
  debugExitLink?: string | null;
}

defineProps<Props>();

defineEmits<{
  (event: 'save'): void;
}>();
</script>

<template>
  <div class="pointer-events-none absolute left-6 top-5 z-30 flex select-none flex-col items-start gap-0.5">
    <div class="px-1.5 py-0.5">
      <div class="flex items-center gap-2">
        <a
          v-if="workspaceLink"
          :href="workspaceLink"
          class="pointer-events-auto select-none text-base-content/60 hover:text-base-content/80 text-xs font-medium transition-colors"
        >
          {{ workspaceName || 'Workspace' }}
        </a>
        <span
          v-else
          class="pointer-events-none text-base-content/60 text-xs font-medium"
        >
          {{ workspaceName || 'Workspace' }}
        </span>
        <SlashIcon class="pointer-events-none text-base-content/30 h-3.5 w-3.5" stroke-width="2.5" />
        <span class="pointer-events-none text-base-content/90 text-xs font-semibold">
          {{ workflowName }}
        </span>
        <div class="pointer-events-none ml-1 flex items-center">
          <Avatar :presences="presences" class="scale-95" />
        </div>
      </div>
    </div>

    <button
      type="button"
      class="pointer-events-auto ml-1 inline-flex select-none items-center gap-1 px-0.5 py-0 text-[10px] font-medium text-base-content/45 transition-colors hover:text-base-content/70"
      :title="lastSavedExact"
      @click="$emit('save')"
    >
      Last saved: {{ lastSaved }}
    </button>

    <div
      v-if="isDebugMode"
      class="pointer-events-auto mt-2 flex flex-col gap-1.5 rounded-xl border border-base-300/50 bg-base-100/80 px-3 py-2.5 shadow-sm backdrop-blur-sm"
    >
      <div class="flex items-center gap-2 text-[11px]">
        <BugAntIcon class="h-3.5 w-3.5 text-base-content/50" />
        <span class="font-semibold text-base-content/70">Debug</span>
        <span class="text-base-content/30">&middot;</span>
        <span class="flex items-center gap-1.5">
          <span
            class="inline-block h-1.5 w-1.5 rounded-full"
            :class="debugStatusBadge.dotClass"
          ></span>
          <span class="font-medium text-base-content/60">{{ debugStatusBadge.label }}</span>
        </span>
        <span class="text-base-content/30">&middot;</span>
        <span class="font-mono text-base-content/50">{{ debugExecutionShortId }}</span>
      </div>
      <div class="flex items-center gap-3">
        <p v-if="debugExecutionTimestamp" class="text-[10px] text-base-content/40">
          {{ debugExecutionTimestamp }}
        </p>
        <div class="flex items-center gap-1.5">
          <a
            v-if="debugExecutionLink"
            :href="debugExecutionLink"
            class="rounded-lg px-2 py-0.5 text-[10px] font-medium text-base-content/50 transition-colors hover:bg-base-200/80 hover:text-base-content/70"
          >
            View execution
          </a>
          <a
            v-if="debugExitLink"
            :href="debugExitLink"
            class="rounded-lg bg-primary/10 px-2 py-0.5 text-[10px] font-medium text-primary transition-colors hover:bg-primary/20"
          >
            Exit debug
          </a>
        </div>
      </div>
    </div>
  </div>
</template>

