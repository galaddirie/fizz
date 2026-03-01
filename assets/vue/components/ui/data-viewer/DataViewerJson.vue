<script setup lang="ts">
import { computed, ref } from 'vue';
import { DocumentDuplicateIcon, CheckIcon } from '@heroicons/vue/24/outline';

interface Props {
  data: unknown;
}

const props = defineProps<Props>();

const copied = ref(false);
let copyTimeout: ReturnType<typeof setTimeout> | null = null;

const formatted = computed(() => {
  if (props.data === undefined) return 'undefined';
  if (props.data === null) return 'null';
  return JSON.stringify(props.data, null, 2);
});

const lines = computed(() => formatted.value.split('\n'));

const lineNumberWidth = computed(() => {
  return String(lines.value.length).length;
});

function copyAll() {
  navigator.clipboard.writeText(formatted.value);
  copied.value = true;
  if (copyTimeout) clearTimeout(copyTimeout);
  copyTimeout = setTimeout(() => { copied.value = false; }, 1500);
}

function highlightLine(line: string): string {
  return line
    // Keys
    .replace(/^(\s*)"([^"]+)"(?=\s*:)/g, '$1<span class="text-base-content/80 font-medium">"$2"</span>')
    // String values
    .replace(/:\s*"([^"]*)"(,?)$/g, ': <span class="text-emerald-600">"$1"</span>$2')
    // Numbers
    .replace(/:\s*(-?\d+\.?\d*)(,?)$/g, ': <span class="text-blue-600">$1</span>$2')
    // Booleans
    .replace(/:\s*(true|false)(,?)$/g, ': <span class="text-violet-600">$1</span>$2')
    // Null
    .replace(/:\s*(null)(,?)$/g, ': <span class="text-base-content/50">$1</span>$2');
}
</script>

<template>
  <div class="rounded-lg bg-base-200/30">
    <!-- Header with copy button -->
    <div class="flex items-center justify-end px-3 py-1.5">
      <button
        @click="copyAll"
        class="flex items-center gap-1 rounded-md border border-base-300/50 bg-base-100 px-2 py-1 text-[11px] font-medium text-base-content/60 transition-all hover:border-base-300 hover:text-base-content/80"
      >
        <CheckIcon v-if="copied" class="size-3 text-success" />
        <DocumentDuplicateIcon v-else class="size-3" />
        {{ copied ? 'Copied' : 'Copy' }}
      </button>
    </div>

    <!-- Content -->
    <div class="overflow-auto font-mono text-xs leading-relaxed">
      <table class="w-full border-collapse">
        <tbody>
          <tr v-for="(line, i) in lines" :key="i" class="hover:bg-base-200/40">
            <td
              class="select-none border-r border-base-200/50 px-3 py-0 text-right text-base-content/35"
              :style="{ minWidth: `${lineNumberWidth + 2}ch` }"
            >
              {{ i + 1 }}
            </td>
            <td class="px-3 py-0 whitespace-pre text-base-content/70" v-html="highlightLine(line)"></td>
          </tr>
        </tbody>
      </table>
    </div>
  </div>
</template>
