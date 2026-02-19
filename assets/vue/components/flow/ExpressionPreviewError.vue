<script setup lang="ts">
import { computed } from 'vue';

interface ErrorPayload {
  type: 'parse_error' | 'render_error';
  message?: string;
  errors?: string[];
  line?: number;
  column?: number;
  text: string;
}

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
  <div class="bg-error/5 border-error/10 space-y-2 rounded-lg border p-3">
    <div class="text-error flex items-center gap-2 text-[10px] font-bold tracking-wider uppercase">
      <div class="bg-error h-1.5 w-1.5 animate-pulse rounded-full" />
      Template Error
    </div>

    <div
      class="bg-base-300/50 border-base-content/5 overflow-x-auto rounded border p-2 font-mono text-[11px] leading-relaxed whitespace-pre"
    >
      <template v-for="(line, idx) in lines" :key="idx">
        <div
          class="flex gap-3"
          :class="{ 'bg-error/5': idx === (props.error.line ? props.error.line - 1 : 0) }"
        >
          <span class="text-base-content/30 w-4 text-right select-none">{{ 1 + idx }}</span>
          <span class="text-base-content/90">{{ line }}</span>
        </div>
        <div
          v-if="idx === (props.error.line ? props.error.line - 1 : 0) && errorMarker"
          class="flex gap-3"
        >
          <span class="w-4" />
          <span class="text-error leading-[0] font-bold">{{ errorMarker }}</span>
        </div>
      </template>
    </div>

    <div class="text-error bg-error/10 rounded p-2 text-[11px] leading-normal whitespace-pre-wrap">
      {{ errorMessage }}
    </div>
  </div>
</template>
