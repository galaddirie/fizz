<script setup lang="ts">
import { inject } from 'vue';
import {
  MagnifyingGlassIcon,
  ChevronRightIcon,
  DocumentDuplicateIcon,
  ArrowRightOnRectangleIcon,
  BoltIcon,
  CpuChipIcon,
  GlobeAltIcon,
  VariableIcon
} from '@heroicons/vue/24/outline';
import DataViewer from '@/components/ui/data-viewer/DataViewer.vue';
import { StepConfigKey } from './useStepConfig';

const state = inject(StepConfigKey)!;

const iconMap: Record<string, any> = {
  ArrowRightOnRectangleIcon,
  BoltIcon,
  CpuChipIcon,
  VariableIcon,
  GlobeAltIcon,
};

const copyPath = (path: string) => window.navigator.clipboard.writeText(path);
</script>

<template>
  <div class="border-base-200 bg-base-100/50 flex w-80 flex-col overflow-hidden border-r">
    <div class="border-base-200 bg-base-200/10 border-b p-4">
      <div class="relative">
        <MagnifyingGlassIcon class="text-base-content/40 absolute top-1/2 left-3 h-4 w-4 -translate-y-1/2" />
        <input
          :value="state.searchQuery.value"
          @input="state.searchQuery.value = ($event.target as HTMLInputElement).value"
          type="text"
          placeholder="Search variables..."
          class="input input-sm input-bordered bg-base-100 border-base-300 focus:border-primary w-full pl-9 text-xs font-medium"
        />
      </div>
    </div>
    <div class="custom-scrollbar flex-1 space-y-1 overflow-y-auto p-2">
      <div v-for="section in state.explorerData.value" :key="section.id" class="overflow-hidden">
        <button
          class="hover:bg-primary/5 group flex w-full items-center justify-between rounded-xl p-2 text-xs font-bold transition-all"
          :class="
            state.expandedSections.value[section.id]
              ? 'text-primary bg-primary/5'
              : 'text-base-content/60'
          "
          @click="state.toggleSection(section.id)"
        >
          <div class="flex items-center gap-2">
            <span class="opacity-70 group-hover:opacity-100">
              <component :is="iconMap[section.icon] || section.icon" class="h-4 w-4" />
            </span>
            {{ section.label }}
          </div>
          <ChevronRightIcon
            :class="{ 'rotate-90': state.expandedSections.value[section.id] }"
            class="h-3 w-3 opacity-40 transition-transform"
          />
        </button>
        <div
          v-if="state.expandedSections.value[section.id]"
          class="border-base-200 mt-1 ml-4 space-y-1 border-l py-1 pl-2 text-wrap"
        >
          <template v-if="section.id === 'json' && state.currentInputState.value.status !== 'available'">
            <div class="bg-base-300/20 space-y-2 rounded-xl p-3">
              <div class="text-base-content text-[11px] font-semibold">
                {{ state.currentInputEmptyState.value.title }}
              </div>
              <p class="text-base-content/60 text-[10px] leading-relaxed">
                {{ state.currentInputEmptyState.value.description }}
              </p>
              <button
                class="btn btn-xs btn-primary w-full"
                :disabled="!state.canEdit.value"
                @click.stop="state.runInput()"
              >
                {{ state.runInputLabel.value }}
              </button>
            </div>
          </template>
          <template
            v-else-if="section.data !== undefined && section.data !== null"
          >
            <div class="overflow-hidden rounded-lg">
              <DataViewer
                :data="section.data"
                :rootPath="section.id"
                :showViewToggle="false"
                defaultView="tree"
                :onCopyPath="copyPath"
              />
            </div>
          </template>
          <div v-else class="text-base-content/40 p-2 text-[10px] italic">
            No variables available
          </div>
        </div>
      </div>
    </div>
    <div class="border-base-200 bg-base-200/5 border-t p-4">
      <div class="text-base-content/40 mb-2 text-[10px] font-bold tracking-wider uppercase">
        Expression Tip
      </div>
      <p class="text-base-content/60 text-[11px] leading-relaxed">
        Click any variable to copy its Liquid expression to your clipboard.
      </p>
    </div>
  </div>
</template>
