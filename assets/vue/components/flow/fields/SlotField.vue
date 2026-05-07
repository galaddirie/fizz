<template>
  <div
    class="flex items-center gap-3 rounded-xl bg-base-200/30 px-3.5 py-2.5 ring-1 ring-base-content/[0.06]"
  >
    <div
      class="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-primary/10 text-primary"
    >
      <svg
        xmlns="http://www.w3.org/2000/svg"
        fill="none"
        viewBox="0 0 24 24"
        stroke-width="1.5"
        stroke="currentColor"
        class="h-4 w-4"
      >
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          d="M16.5 10.5V6.75a4.5 4.5 0 1 0-9 0v3.75m-.75 11.25h10.5a2.25 2.25 0 0 0 2.25-2.25v-6.75a2.25 2.25 0 0 0-2.25-2.25H6.75a2.25 2.25 0 0 0-2.25 2.25v6.75a2.25 2.25 0 0 0 2.25 2.25Z"
        />
      </svg>
    </div>

    <div class="min-w-0 flex-1">
      <p class="text-sm font-medium text-base-content">
        Bound at run time per user
      </p>
      <p class="mt-0.5 truncate text-[11px] leading-relaxed text-base-content/50">
        {{ summary }}
      </p>
    </div>
  </div>

  <p
    v-if="field.description"
    class="mt-1.5 text-[11px] leading-relaxed text-base-content/40"
  >
    {{ field.description }}
  </p>
</template>

<script setup lang="ts">
import { computed } from 'vue';

import type { ConfigField } from '@/types/configSchema';

const props = defineProps<{ field: ConfigField }>();

const summary = computed(() => {
  const ui = props.field?.ui;
  const kind = ui?.slot_kind ?? 'slot';
  const spec = ui?.spec ?? {};
  const provider = typeof spec['provider'] === 'string' ? spec['provider'] : null;
  const authType = typeof spec['auth_type'] === 'string' ? spec['auth_type'] : null;

  if (kind === 'credential' && provider) {
    return authType ? `${provider} (${authType})` : provider;
  }

  return kind;
});
</script>
