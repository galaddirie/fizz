<script setup lang="ts">
import { computed } from 'vue';
import type { ErrorPayload } from './useExpressionPreviews';

const props = defineProps<{
  error: ErrorPayload;
}>();

const errorMessage = computed(() => {
  if (props.error.message) return props.error.message;
  if (props.error.errors?.length) return props.error.errors.join('\n');
  return 'Unknown error';
});

const lines = computed(() => props.error.text.split('\n'));

// For now we only highlight the specific character at the column
const errorMarker = computed(() => {
  if (props.error.column === undefined) return null;

  // column is usually 1-indexed
  const col = props.error.column - 1;
  return ' '.repeat(col) + '^';
});
</script>

<template>
  <div class="space-y-2 rounded-xl bg-error/[0.04] p-3 ring-1 ring-error/10" role="alert">
    <div class="flex items-center gap-2 text-[10px] font-bold uppercase tracking-wider text-error">
      <div class="h-1.5 w-1.5 animate-pulse rounded-full bg-error" />
      Template Error
    </div>

    <div
      class="overflow-x-auto rounded-lg bg-base-300/40 p-2 font-mono text-[11px] leading-relaxed ring-1 ring-base-content/[0.04] whitespace-pre"
    >
      <template v-for="(line, idx) in lines" :key="idx">
        <div
          class="flex gap-3"
          :class="{ 'bg-error/[0.06]': idx === (props.error.line ? props.error.line - 1 : 0) }"
        >
          <span class="w-4 text-right text-base-content/25 select-none">{{ 1 + idx }}</span>
          <span class="text-base-content/80">{{ line }}</span>
        </div>
        <div
          v-if="idx === (props.error.line ? props.error.line - 1 : 0) && errorMarker"
          class="flex gap-3"
        >
          <span class="w-4" />
          <span class="font-bold leading-[0] text-error">{{ errorMarker }}</span>
        </div>
      </template>
    </div>

    <div class="rounded-lg bg-error/8 p-2 text-[11px] leading-normal text-error whitespace-pre-wrap">
      {{ errorMessage }}
    </div>
  </div>
</template>
