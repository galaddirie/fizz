<script setup lang="ts">
import { inject } from 'vue';
import {
  MagnifyingGlassIcon,
  ChevronRightIcon,
} from '@heroicons/vue/24/outline';
import DataViewer from '@/components/ui/data-viewer/DataViewer.vue';
import { StepConfigKey } from './useStepConfig';

const state = inject(StepConfigKey)!;

const copyPath = (path: string) => window.navigator.clipboard.writeText(path);
</script>

<template>
  <div class="flex w-80 flex-col overflow-hidden border-r border-base-200/60">
    <!-- Search -->
    <div class="shrink-0 px-4 pt-4 pb-2">
      <div class="relative">
        <MagnifyingGlassIcon class="absolute top-1/2 left-3 h-3.5 w-3.5 -translate-y-1/2 text-base-content/35" />
        <input
          :value="state.searchQuery.value"
          @input="state.searchQuery.value = ($event.target as HTMLInputElement).value"
          type="text"
          placeholder="Search variables..."
          class="w-full rounded-lg border border-base-200/60 bg-transparent py-2 pl-9 pr-3 text-xs font-medium text-base-content placeholder:text-base-content/30 outline-none transition-colors focus:border-base-content/20"
        />
      </div>
    </div>

    <!-- Sections -->
    <div class="custom-scrollbar flex-1 overflow-y-auto px-2 py-1">
      <div v-for="section in state.explorerData.value" :key="section.id">
        <button
          class="group flex w-full items-center justify-between rounded-lg px-2 py-2 text-xs font-medium transition-colors"
          :class="
            state.expandedSections.value[section.id]
              ? 'text-base-content'
              : 'text-base-content/50 hover:text-base-content/70'
          "
          @click="state.toggleSection(section.id)"
        >
          {{ section.label }}
          <ChevronRightIcon
            :class="{ 'rotate-90': state.expandedSections.value[section.id] }"
            class="h-3 w-3 opacity-35 transition-transform"
          />
        </button>

        <div
          v-if="state.expandedSections.value[section.id]"
          class="pb-2"
        >
          <!-- Empty input state -->
          <template v-if="section.id === 'json' && state.currentInputState.value.status !== 'available'">
            <div class="mx-2 space-y-2 border-t border-base-200/40 pt-3 pb-1">
              <div class="text-[11px] font-medium text-base-content/70">
                {{ state.currentInputEmptyState.value.title }}
              </div>
              <p class="text-[10px] leading-relaxed text-base-content/40">
                {{ state.currentInputEmptyState.value.description }}
              </p>
              <button
                class="w-full rounded-lg bg-primary px-3 py-1.5 text-[11px] font-medium text-primary-content transition-all hover:brightness-110"
                :disabled="!state.canEdit.value"
                @click.stop="state.runInput()"
              >
                {{ state.runInputLabel.value }}
              </button>
            </div>
          </template>

          <!-- Data viewer -->
          <template
            v-else-if="section.data !== undefined && section.data !== null"
          >
            <div class="mx-1 overflow-hidden border-t border-base-200/40">
              <DataViewer
                :data="section.data"
                :rootPath="section.id"
                :showViewToggle="false"
                defaultView="tree"
                :onCopyPath="copyPath"
              />
            </div>
          </template>

          <!-- Empty -->
          <div v-else class="mx-2 border-t border-base-200/40 pt-3 text-[11px] text-base-content/30">
            No variables available
          </div>
        </div>
      </div>
    </div>
  </div>
</template>
