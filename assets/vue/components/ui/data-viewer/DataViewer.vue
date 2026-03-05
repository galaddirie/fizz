<script setup lang="ts">
import { computed, toRef, watch } from 'vue';
import {
  ChevronDoubleDownIcon,
  ChevronDoubleUpIcon,
} from '@heroicons/vue/24/outline';
import { type ViewMode } from './types';
import { useDataViewer } from './useDataViewer';
import DataViewerTree from './DataViewerTree.vue';
import DataViewerJson from './DataViewerJson.vue';

interface Props {
  data: unknown;
  rootPath?: string;
  maxHeight?: string;
  defaultView?: ViewMode;
  showViewToggle?: boolean;
  onCopyPath?: ((path: string) => void) | null;
}

const props = withDefaults(defineProps<Props>(), {
  rootPath: '',
  maxHeight: '',
  defaultView: 'tree',
  showViewToggle: true,
  onCopyPath: null,
});

const dataRef = toRef(props, 'data');

const {
  viewMode,
  effectiveViewMode,
  expandedPaths,
  copiedPath,
  toggleExpanded,
  expandAll,
  collapseAll,
  expandToDepth,
  copyToClipboard,
} = useDataViewer(props.defaultView);

// Auto-expand first level on data change
watch(dataRef, (newData) => {
  expandedPaths.value.clear();
  expandToDepth(newData, 1);
}, { immediate: true });

const handleCopy = (expression: string) => {
  copyToClipboard(expression);
  props.onCopyPath?.(expression);
};

const hasData = computed(() => props.data !== null && props.data !== undefined);
const isExpandable = computed(() => props.data && typeof props.data === 'object');

const viewModes: { id: ViewMode; label: string; icon: string }[] = [
  { id: 'tree', label: 'Tree', icon: '{}' },
  { id: 'json', label: 'JSON', icon: '</>' },
];
</script>

<template>
  <div class="flex flex-col overflow-hidden" :style="maxHeight ? { maxHeight } : {}">
    <!-- Toolbar -->
    <div
      v-if="showViewToggle && hasData"
      class="flex shrink-0 items-center justify-between border-b border-base-200/60 px-2 py-1.5"
    >
      <!-- View mode tabs -->
      <div class="flex items-center gap-0.5 rounded-md bg-base-200/40 p-0.5">
        <button
          v-for="mode in viewModes"
          :key="mode.id"
          @click="viewMode = mode.id"
          :title="mode.label"
          :class="[
            'rounded px-2.5 py-1 text-[11px] font-medium transition-all cursor-pointer',
            effectiveViewMode === mode.id
              ? 'bg-base-100 text-base-content shadow-sm'
              : 'text-base-content/55 hover:text-base-content/75',
          ]"
        >
          <span class="mr-1 font-mono text-[10px] opacity-60">{{ mode.icon }}</span>
          {{ mode.label }}
        </button>
      </div>

      <!-- Tree controls -->
      <div v-if="effectiveViewMode === 'tree' && isExpandable" class="flex items-center gap-1">
        <button
          @click="expandAll(data)"
          class="rounded p-1 text-base-content/40 transition-colors hover:bg-base-200/60 hover:text-base-content/70"
          title="Expand all"
        >
          <ChevronDoubleDownIcon class="size-3.5" />
        </button>
        <button
          @click="collapseAll()"
          class="rounded p-1 text-base-content/40 transition-colors hover:bg-base-200/60 hover:text-base-content/70"
          title="Collapse all"
        >
          <ChevronDoubleUpIcon class="size-3.5" />
        </button>
      </div>
    </div>

    <!-- Content -->
    <div class="custom-scrollbar flex-1 overflow-auto">
      <template v-if="hasData">
        <DataViewerTree
          v-if="effectiveViewMode === 'tree'"
          :data="data"
          :rootPath="rootPath"
          :expandedPaths="expandedPaths"
          :copiedPath="copiedPath"
          :onToggle="toggleExpanded"
          :onCopy="rootPath ? handleCopy : undefined"
        />
        <DataViewerJson
          v-else
          :data="data"
        />
      </template>

      <div v-else class="flex items-center justify-center py-8 text-sm text-base-content/45">
        No data available
      </div>
    </div>

    <!-- Copy toast -->
    <Transition
      enter-active-class="transition-all duration-200 ease-out"
      enter-from-class="translate-y-2 opacity-0"
      enter-to-class="translate-y-0 opacity-100"
      leave-active-class="transition-all duration-150 ease-in"
      leave-from-class="translate-y-0 opacity-100"
      leave-to-class="translate-y-2 opacity-0"
    >
      <div
        v-if="copiedPath"
        class="absolute bottom-3 left-1/2 -translate-x-1/2 rounded-lg bg-base-content px-3 py-1.5 text-[11px] font-medium text-base-100 shadow-lg"
      >
        Copied: <span class="font-mono opacity-70">{{ copiedPath }}</span>
      </div>
    </Transition>
  </div>
</template>

<style scoped>
.custom-scrollbar::-webkit-scrollbar {
  width: 6px;
  height: 6px;
}
.custom-scrollbar::-webkit-scrollbar-thumb {
  background: color-mix(in oklch, var(--color-base-content) 10%, transparent);
  border-radius: 999px;
}
.custom-scrollbar::-webkit-scrollbar-track {
  background: transparent;
}
</style>
