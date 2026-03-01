<script setup lang="ts">
import { ref, inject, computed } from 'vue';
import { BookmarkIcon, DocumentDuplicateIcon, BoltIcon, ChevronLeftIcon, ChevronRightIcon } from '@heroicons/vue/24/outline';
import { colorMap, oklchToHex, statusLabels, type NodeStatus } from '@/lib/color';
import { unwrapData } from '@/lib/dataUtils';
import DataViewer from '@/components/ui/data-viewer/DataViewer.vue';
import { StepConfigKey } from './useStepConfig';

const state = inject(StepConfigKey)!;

type Tab = 'input' | 'output';
const activeTab = ref<Tab>('output');

const hasContent = () => state.activeStepExecution.value || state.hasPinnedOutput.value;

const effectiveStatus = computed<NodeStatus | null>(() => {
  if (state.hasPinnedOutput.value) return 'pinned';
  const status = state.activeStepExecution.value?.status as NodeStatus | undefined;
  return status && status !== 'pending' ? status : null;
});

const statusColor = computed(() => {
  const s = effectiveStatus.value;
  return s ? oklchToHex(colorMap[s]) : null;
});

const getStatusColor = (status: string) => oklchToHex(colorMap[status as NodeStatus] || colorMap.pending);
const getStatusLabel = (status: string) => statusLabels[status as NodeStatus] || status;

const copyPath = (path: string) => window.navigator.clipboard.writeText(path);
</script>

<template>
  <div class="flex h-full flex-col">
    <template v-if="hasContent()">
      <!-- Tab Bar -->
      <div class="border-base-200 shrink-0 border-b">
        <div class="flex">
          <button
            v-if="state.activeStepExecution.value"
            @click="activeTab = 'input'"
            :class="[
              'relative px-4 py-2.5 text-xs font-medium transition-colors',
              activeTab === 'input'
                ? 'text-base-content'
                : 'text-base-content/50 hover:text-base-content/70',
            ]"
          >
            Input
            <span
              v-if="activeTab === 'input'"
              class="bg-primary absolute bottom-0 left-0 h-0.5 w-full"
            ></span>
          </button>
          <button
            @click="activeTab = 'output'"
            :class="[
              'relative flex items-center gap-1.5 px-4 py-2.5 text-xs font-medium transition-colors',
              activeTab === 'output'
                ? 'text-base-content'
                : 'text-base-content/50 hover:text-base-content/70',
            ]"
          >
            Output
            <span
              v-if="effectiveStatus"
              class="inline-flex items-center rounded-full px-1.5 py-px text-[10px] font-bold leading-tight"
              :style="{
                backgroundColor: (statusColor ?? '') + '25',
                color: statusColor ?? undefined,
              }"
            >{{ statusLabels[effectiveStatus] }}</span>
            <span
              v-if="activeTab === 'output'"
              class="bg-primary absolute bottom-0 left-0 h-0.5 w-full"
            ></span>
          </button>
        </div>
      </div>

      <!-- Item Navigator -->
      <div
        v-if="state.activeStepExecution.value && state.isMultiItemStep.value && state.itemStats.value"
        class="border-base-200 shrink-0 border-b px-4 py-2"
      >
        <div class="flex items-center justify-between gap-3 text-xs">
          <div class="flex items-center gap-1.5">
            <button
              @click="state.selectedItemIndex.value = Math.max(0, (state.selectedItemIndex.value ?? 0) - 1)"
              :disabled="(state.selectedItemIndex.value ?? 0) <= 0"
              class="text-base-content/40 rounded p-0.5 transition-colors hover:text-base-content/70 disabled:opacity-30"
            >
              <ChevronLeftIcon class="size-3.5" />
            </button>
            <span class="text-base-content/55">Item</span>
            <span class="text-base-content font-semibold">#{{ (state.selectedItemIndex.value ?? 0) + 1 }}</span>
            <span class="text-base-content/40">/ {{ state.itemStats.value.itemsTotal }}</span>
            <button
              @click="state.selectedItemIndex.value = Math.min(state.itemStats.value.itemsTotal - 1, (state.selectedItemIndex.value ?? 0) + 1)"
              :disabled="(state.selectedItemIndex.value ?? 0) >= state.itemStats.value.itemsTotal - 1"
              class="text-base-content/40 rounded p-0.5 transition-colors hover:text-base-content/70 disabled:opacity-30"
            >
              <ChevronRightIcon class="size-3.5" />
            </button>
          </div>
          <div class="flex items-center gap-1.5 text-[11px]">
            <span
              v-if="state.itemStats.value.completed > 0"
              class="flex items-center gap-1"
              :style="{ color: getStatusColor('completed') }"
            >
              <span class="inline-block size-1.5 rounded-full" :style="{ backgroundColor: getStatusColor('completed') }"></span>
              {{ state.itemStats.value.completed }}
            </span>
            <span
              v-if="state.itemStats.value.failed > 0"
              class="flex items-center gap-1"
              :style="{ color: getStatusColor('failed') }"
            >
              <span class="inline-block size-1.5 rounded-full" :style="{ backgroundColor: getStatusColor('failed') }"></span>
              {{ state.itemStats.value.failed }}
            </span>
            <span
              v-if="state.itemStats.value.running > 0"
              class="flex items-center gap-1"
              :style="{ color: getStatusColor('running') }"
            >
              <span class="inline-block size-1.5 rounded-full animate-pulse" :style="{ backgroundColor: getStatusColor('running') }"></span>
              {{ state.itemStats.value.running }}
            </span>
          </div>
        </div>
      </div>

      <!-- Tab Content -->
      <div class="custom-scrollbar flex-1 overflow-y-auto p-4">
        <!-- Action bar (shared layout for both tabs) -->
        <div class="mb-3 flex min-h-[24px] items-center justify-end">
          <div class="flex items-center gap-2">
            <template v-if="activeTab === 'input'">
              <button
                @click.stop="state.copyExpression('json')"
                class="text-base-content/50 flex items-center gap-1 text-[11px] transition-colors hover:text-base-content/70"
              >
                <DocumentDuplicateIcon class="size-3.5" />
                Copy
              </button>
            </template>
            <template v-if="activeTab === 'output' && state.canEdit.value && (state.hasPinnedOutput.value || state.activeStepExecution.value)">
              <button
                v-if="!state.hasPinnedOutput.value && state.activeStepExecution.value"
                @click.stop="state.pinOutput()"
                :disabled="!state.canPinOutput.value"
                :title="
                  state.canPinOutput.value
                    ? 'Pin this output for previews'
                    : 'Run the workflow to capture output before pinning'
                "
                class="text-base-content/50 flex items-center gap-1 text-[11px] transition-colors hover:text-base-content/70 disabled:opacity-30"
              >
                <BookmarkIcon class="size-3.5" />
                Pin
              </button>

              <button
                v-if="state.hasPinnedOutput.value"
                @click.stop="state.unpinOutput()"
                class="text-error/50 flex items-center gap-1 text-[11px] transition-colors hover:text-error"
              >
                Unpin
              </button>
            </template>
          </div>
        </div>

        <!-- INPUT TAB -->
        <div v-if="activeTab === 'input' && state.activeStepExecution.value">
          <div class="overflow-hidden rounded-xl border border-base-200/60">
            <DataViewer
              :data="unwrapData(state.activeStepExecution.value.input_data)"
              rootPath="json"
              :onCopyPath="copyPath"
            />
          </div>
        </div>

        <!-- OUTPUT TAB -->
        <div v-if="activeTab === 'output'">
          <!-- Output Data Block -->
          <div>
            <div
              class="overflow-hidden rounded-xl border transition-all duration-200"
              :class="[
                state.hasPinnedOutput.value
                  ? 'border-transparent'
                  : 'border-base-200/60',
              ]"
              :style="state.hasPinnedOutput.value ? {
                backgroundColor: oklchToHex(colorMap.pinned) + '0A',
                borderLeft: `3px solid ${oklchToHex(colorMap.pinned)}40`,
              } : {}"
            >
              <DataViewer
                :data="unwrapData(state.hasPinnedOutput.value ? state.pinnedOutput.value : state.activeStepExecution.value?.output_data)"
                :rootPath="`steps.${state.nodeId.value}`"
                :onCopyPath="copyPath"
              />
            </div>
          </div>

          <!-- Error (inline in output tab) -->
          <div v-if="state.activeStepExecution.value?.error && state.activeStepExecution.value.error !== 'nil'" class="mt-4">
            <h4 class="text-error/60 mb-2 text-[11px] font-semibold tracking-widest uppercase">
              Error
            </h4>
            <div
              class="border-error/20 bg-error/5 text-error/80 overflow-x-auto rounded-xl border-l-[3px] p-4 font-mono text-xs leading-relaxed"
            >{{ state.activeStepExecution.value.error }}</div>
          </div>
        </div>
      </div>
    </template>

    <!-- Empty State -->
    <div v-else class="flex h-full flex-col items-center justify-center">
      <BoltIcon class="text-base-content/20 mb-3 size-12" />
      <p class="text-base-content/45 text-sm font-medium">No output yet</p>
      <p class="text-base-content/35 mt-1 text-xs">Run the workflow to see results</p>
    </div>
  </div>
</template>
