<script setup lang="ts">
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
import { formatDataForDisplay } from '@/lib/dataUtils';

const props = defineProps<{
  searchQuery: string;
  explorerData: any[];
  expandedSections: Record<string, boolean>;
  currentInputState: any;
  currentInputEmptyState: any;
  runInputLabel: string;
  canEdit: boolean;
}>();

const emit = defineEmits<{
  (e: 'update:searchQuery', value: string): void;
  (e: 'toggleSection', id: string): void;
  (e: 'runInput'): void;
  (e: 'copyExpression', sectionId: string, key?: string): void;
  (e: 'formatSectionKey', sectionId: string, key: string): string;
  (e: 'getExpressionFor', sectionId: string, key?: string): string;
}>();

const iconMap: Record<string, any> = {
  ArrowRightOnRectangleIcon,
  BoltIcon,
  CpuChipIcon,
  VariableIcon,
  GlobeAltIcon,
};
</script>

<template>
  <div class="border-base-200 bg-base-100/50 flex w-80 flex-col overflow-hidden border-r">
    <div class="border-base-200 bg-base-200/10 border-b p-4">
      <div class="relative">
        <MagnifyingGlassIcon class="text-base-content/40 absolute top-1/2 left-3 h-4 w-4 -translate-y-1/2" />
        <input
          :value="searchQuery"
          @input="emit('update:searchQuery', ($event.target as HTMLInputElement).value)"
          type="text"
          placeholder="Search variables..."
          class="input input-sm input-bordered bg-base-100 border-base-300 focus:border-primary w-full pl-9 text-xs font-medium"
        />
      </div>
    </div>
    <div class="custom-scrollbar flex-1 space-y-1 overflow-y-auto p-2">
      <div v-for="section in explorerData" :key="section.id" class="overflow-hidden">
        <button
          class="hover:bg-primary/5 group flex w-full items-center justify-between rounded-xl p-2 text-xs font-bold transition-all"
          :class="
            expandedSections[section.id]
              ? 'text-primary bg-primary/5'
              : 'text-base-content/60'
          "
          @click="emit('toggleSection', section.id)"
        >
          <div class="flex items-center gap-2">
            <span class="opacity-70 group-hover:opacity-100">
              <component :is="iconMap[section.icon] || section.icon" class="h-4 w-4" />
            </span>
            {{ section.label }}
          </div>
          <ChevronRightIcon
            :class="{ 'rotate-90': expandedSections[section.id] }"
            class="h-3 w-3 opacity-40 transition-transform"
          />
        </button>
        <div
          v-if="expandedSections[section.id]"
          class="border-base-200 mt-1 ml-4 space-y-1 border-l py-1 pl-2 text-wrap"
        >
          <template v-if="section.id === 'json' && currentInputState.status !== 'available'">
            <div class="bg-base-300/20 space-y-2 rounded-xl p-3">
              <div class="text-base-content text-[11px] font-semibold">
                {{ currentInputEmptyState.title }}
              </div>
              <p class="text-base-content/60 text-[10px] leading-relaxed">
                {{ currentInputEmptyState.description }}
              </p>
              <button
                class="btn btn-xs btn-primary w-full"
                :disabled="!canEdit"
                @click.stop="emit('runInput')"
              >
                {{ runInputLabel }}
              </button>
            </div>
          </template>
          <template
            v-else-if="
              section.data &&
              typeof section.data === 'object' &&
              Object.keys(section.data).length > 0
            "
          >
            <div
              v-for="(val, key) in section.data"
              :key="key"
              class="hover:bg-base-200 group cursor-pointer rounded-lg p-1.5 transition-all"
            >
              <div class="flex items-center justify-between">
                <span class="text-base-content font-mono text-[11px]">
                  <!-- Note: this assumes formatSectionKey was passed or we provide it -->
                  {{ section.id === 'json' ? key : key }}
                </span>
                <button
                  @click.stop="emit('copyExpression', section.id, String(key))"
                  class="btn btn-xs btn-ghost btn-square h-4 w-4 opacity-0 transition-opacity group-hover:opacity-100"
                  title="Copy expression"
                >
                  <DocumentDuplicateIcon class="h-3 w-3" />
                </button>
              </div>
              <div class="text-base-content/40 mt-0.5 truncate text-[10px]">
                {{ JSON.stringify(val) }}
              </div>
            </div>
          </template>
          <div
            v-else-if="section.data !== undefined && section.data !== null"
            class="bg-base-300/10 group rounded-lg p-1.5"
          >
            <div class="flex items-center justify-between gap-2">
              <div class="text-base-content/60 flex-1 truncate font-mono text-[10px]">
                {{ formatDataForDisplay(section.data) }}
              </div>
              <button
                @click.stop="emit('copyExpression', section.id)"
                class="btn btn-xs btn-ghost btn-square h-4 w-4 opacity-0 transition-opacity group-hover:opacity-100"
                title="Copy expression"
              >
                <DocumentDuplicateIcon class="h-3 w-3" />
              </button>
            </div>
          </div>
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
