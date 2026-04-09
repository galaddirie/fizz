<script setup lang="ts">
import { computed } from 'vue';
import { ChevronRightIcon, DocumentDuplicateIcon, CheckIcon } from '@heroicons/vue/24/outline';
import {
  type TreeNode,
  typeColors,
  buildTreeNodes,
  buildLiquidPath,
  formatTreeValue,
  getTypeLabel,
  getCollapsedPreview,
} from './types';

interface Props {
  node: TreeNode;
  depth: number;
  expandedPaths: Set<string>;
  copiedPath?: string | null;
  rootPath?: string;
  onToggle: (path: string) => void;
  onCopy?: ((expression: string) => void) | null;
}

const props = withDefaults(defineProps<Props>(), {
  copiedPath: null,
  rootPath: '',
  onCopy: null,
});

const isExpanded = computed(() => props.expandedPaths.has(props.node.path));

const children = computed<TreeNode[]>(() => {
  if (!isExpanded.value || !props.node.isExpandable) return [];
  return buildTreeNodes(props.node.value, props.node.path, props.node.segments);
});

const indent = computed(() => props.depth * 20 + 4);

const copiedExpression = computed(() => {
  if (!props.rootPath) return null;
  return buildLiquidPath(props.rootPath, props.node.segments);
});

const isCopied = computed(() => props.copiedPath === copiedExpression.value);

function handleCopy() {
  if (!props.onCopy || !props.rootPath) return;
  props.onCopy(buildLiquidPath(props.rootPath, props.node.segments));
}
</script>

<template>
  <div>
    <div
      class="group/row flex items-center gap-1 rounded-md px-1 py-[3px] transition-colors hover:bg-base-200/50 cursor-default"
      :style="{ paddingLeft: `${indent}px` }"
      @click="node.isExpandable ? onToggle(node.path) : undefined"
    >
      <button
        v-if="node.isExpandable"
        class="shrink-0 rounded p-0.5 text-base-content/50 transition-colors hover:text-base-content/80 hover:bg-base-200/60"
        @click.stop="onToggle(node.path)"
      >
        <ChevronRightIcon
          class="size-3.5 transition-transform"
          :class="{ 'rotate-90': isExpanded }"
        />
      </button>
      <span v-else class="w-[18px] shrink-0"></span>

      <span class="shrink-0 font-mono text-base-content/80 font-medium">
        {{ typeof node.key === 'number' ? String(node.key) : node.key }}
      </span>

      <span class="text-base-content/35 shrink-0 mx-1">:</span>

      <template v-if="node.isExpandable">
        <span v-if="!isExpanded" class="truncate font-mono text-base-content/55">
          {{ getCollapsedPreview(node.value, node.type) }}
        </span>
        <span
          :class="[typeColors[node.type].text, typeColors[node.type].bg]"
          class="ml-1 shrink-0 rounded px-1.5 py-0.5 text-[10px] font-medium"
        >
          {{ getTypeLabel(node.value) }}
        </span>
      </template>
      <template v-else>
        <span :class="typeColors[node.type].text" class="truncate font-mono">
          {{ formatTreeValue(node.value, node.type) }}
        </span>
        <span
          :class="[typeColors[node.type].text, typeColors[node.type].bg]"
          class="ml-1.5 shrink-0 rounded px-1.5 py-0.5 text-[10px] font-medium opacity-60"
        >
          {{ node.type }}
        </span>
      </template>

      <button
        v-if="onCopy && rootPath"
        @click.stop="handleCopy"
        class="ml-auto shrink-0 rounded p-1 text-base-content/0 transition-colors group-hover/row:text-base-content/40 hover:!text-base-content/70"
        title="Copy expression"
      >
        <CheckIcon v-if="isCopied" class="size-3.5 text-success" />
        <DocumentDuplicateIcon v-else class="size-3.5" />
      </button>
    </div>

    <TreeNodeRow
      v-for="child in children"
      :key="child.path"
      :node="child"
      :depth="depth + 1"
      :expandedPaths="expandedPaths"
      :copiedPath="copiedPath"
      :rootPath="rootPath"
      :onToggle="onToggle"
      :onCopy="onCopy"
    />
  </div>
</template>
