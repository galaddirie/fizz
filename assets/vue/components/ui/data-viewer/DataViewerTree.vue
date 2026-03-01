<script setup lang="ts">
import { computed } from 'vue';
import { DocumentDuplicateIcon, CheckIcon } from '@heroicons/vue/24/outline';
import {
  getDataType,
  typeColors,
  formatTreeValue,
  buildTreeNodes,
  type TreeNode,
} from './types';
import TreeNodeRow from './TreeNodeRow.vue';

interface Props {
  data: unknown;
  rootPath?: string;
  expandedPaths: Set<string>;
  copiedPath?: string | null;
  onToggle: (path: string) => void;
  onCopy?: ((expression: string) => void) | null;
}

const props = withDefaults(defineProps<Props>(), {
  rootPath: '',
  copiedPath: null,
  onCopy: null,
});

const rootNodes = computed<TreeNode[]>(() => {
  return buildTreeNodes(props.data, '$', []);
});

function handleCopyRoot() {
  if (!props.onCopy || !props.rootPath) return;
  props.onCopy(`{{ ${props.rootPath} }}`);
}
</script>

<template>
  <!-- Primitive root value -->
  <div
    v-if="rootNodes.length === 0 && data !== null && data !== undefined"
    class="flex items-center gap-2 px-2 py-1.5"
  >
    <span :class="[typeColors[getDataType(data)].text]" class="font-mono text-xs">
      {{ formatTreeValue(data, getDataType(data)) }}
    </span>
    <span
      :class="[typeColors[getDataType(data)].text, typeColors[getDataType(data)].bg]"
      class="rounded px-1.5 py-0.5 text-[10px] font-medium"
    >
      {{ getDataType(data) }}
    </span>
    <button
      v-if="onCopy && rootPath"
      @click="handleCopyRoot"
      class="ml-auto rounded p-1 text-base-content/25 transition-colors hover:text-base-content/60"
      title="Copy expression"
    >
      <CheckIcon v-if="copiedPath === `{{ ${rootPath} }}`" class="size-3.5 text-success" />
      <DocumentDuplicateIcon v-else class="size-3.5" />
    </button>
  </div>

  <!-- Null/undefined root -->
  <div
    v-else-if="data === null || data === undefined"
    class="px-2 py-1.5 font-mono text-xs text-base-content/40"
  >
    {{ data === null ? 'null' : 'undefined' }}
  </div>

  <!-- Tree nodes -->
  <div v-else class="text-xs">
    <TreeNodeRow
      v-for="node in rootNodes"
      :key="node.path"
      :node="node"
      :depth="0"
      :expandedPaths="expandedPaths"
      :copiedPath="copiedPath"
      :rootPath="rootPath"
      :onToggle="onToggle"
      :onCopy="onCopy"
    />
  </div>
</template>
