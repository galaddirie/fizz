<script setup lang="ts">
import { ref, inject, computed } from 'vue';
import { BookmarkIcon, DocumentDuplicateIcon, BoltIcon, ChevronLeftIcon, ChevronRightIcon } from '@heroicons/vue/24/outline';
import { formatDataForDisplay } from '@/lib/dataUtils';
import { colorMap, oklchToHex, statusLabels, type NodeStatus } from '@/lib/color';
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
                : 'text-base-content/40 hover:text-base-content/60',
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
                : 'text-base-content/40 hover:text-base-content/60',
            ]"
          >
            Output
            <span
              v-if="effectiveStatus"
              class="inline-flex items-center rounded-full px-1.5 py-px text-[9px] font-semibold leading-tight"
              :style="{
                backgroundColor: statusColor + '18',
                color: statusColor,
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
        <div class="flex items-center justify-between text-xs">
          <div v-if="state.selectedItemIndex.value !== null" class="flex items-center gap-1.5">
            <button
              @click="state.selectedItemIndex.value = Math.max(0, state.selectedItemIndex.value - 1)"
              :disabled="state.selectedItemIndex.value <= 0"
              class="text-base-content/30 rounded p-0.5 transition-colors hover:text-base-content/60 disabled:opacity-30"
            >
              <ChevronLeftIcon class="size-3.5" />
            </button>
            <span class="text-base-content/40">Item</span>
            <span class="text-base-content font-semibold">#{{ state.selectedItemIndex.value + 1 }}</span>
            <span class="text-base-content/30">/ {{ state.itemStats.value.itemsTotal }}</span>
            <button
              @click="state.selectedItemIndex.value = Math.min(state.itemStats.value.itemsTotal - 1, state.selectedItemIndex.value + 1)"
              :disabled="state.selectedItemIndex.value >= state.itemStats.value.itemsTotal - 1"
              class="text-base-content/30 rounded p-0.5 transition-colors hover:text-base-content/60 disabled:opacity-30"
            >
              <ChevronRightIcon class="size-3.5" />
            </button>
          </div>
          <div v-else class="flex items-center gap-2">
            <span class="text-base-content/50 font-medium">{{ state.itemStats.value.itemsTotal }} items</span>
            <div class="flex items-center gap-1.5 text-[10px]">
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
          <button
            v-if="state.selectedItemIndex.value !== null"
            @click="state.selectedItemIndex.value = null"
            class="text-base-content/30 text-[10px] font-medium transition-colors hover:text-base-content/60"
          >Show All</button>
          <button
            v-else
            @click="state.selectedItemIndex.value = 0"
            class="text-base-content/30 text-[10px] font-medium transition-colors hover:text-base-content/60"
          >Browse Items</button>
        </div>
      </div>

      <!-- Tab Content -->
      <div class="custom-scrollbar flex-1 overflow-y-auto p-4">
        <!-- INPUT TAB -->
        <div v-if="activeTab === 'input' && state.activeStepExecution.value">
          <div class="mb-3 flex items-center justify-between">
            <h4 class="text-base-content/30 text-[10px] font-semibold tracking-widest uppercase">
              Input Data
            </h4>
            <button
              @click.stop="state.copyExpression('json')"
              class="text-base-content/30 flex items-center gap-1 text-[10px] transition-colors hover:text-base-content/60"
            >
              <DocumentDuplicateIcon class="size-3" />
              Copy
            </button>
          </div>
          <div class="bg-base-200/40 overflow-x-auto rounded-xl p-4 font-mono text-xs leading-relaxed whitespace-pre text-base-content/70">{{ formatDataForDisplay(state.activeStepExecution.value.input_data) }}</div>
        </div>

        <!-- OUTPUT TAB -->
        <div v-if="activeTab === 'output'" class="space-y-4">
          <!-- Output actions -->
          <div
            v-if="state.canEdit.value && (state.hasPinnedOutput.value || state.activeStepExecution.value)"
            class="flex items-center justify-end"
          >
            <div class="flex items-center gap-2">
              <button
                v-if="!state.hasPinnedOutput.value && state.activeStepExecution.value"
                @click.stop="state.pinOutput()"
                :disabled="!state.canPinOutput.value"
                :title="
                  state.canPinOutput.value
                    ? 'Pin this output for previews'
                    : 'Run the workflow to capture output before pinning'
                "
                class="text-base-content/30 flex items-center gap-1 text-[10px] transition-colors hover:text-base-content/60 disabled:opacity-30"
              >
                <BookmarkIcon class="size-3" />
                Pin
              </button>

              <button
                v-if="state.hasPinnedOutput.value"
                @click.stop="state.unpinOutput()"
                class="text-error/40 flex items-center gap-1 text-[10px] transition-colors hover:text-error"
              >
                Unpin
              </button>

              <button
                v-if="state.activeStepExecution.value"
                @click.stop="state.copyExpression('steps', state.nodeId.value)"
                class="text-base-content/30 flex items-center gap-1 text-[10px] transition-colors hover:text-base-content/60"
              >
                <DocumentDuplicateIcon class="size-3" />
                Copy
              </button>
            </div>
          </div>

          <!-- Output Data Block -->
          <div>
            <h4 class="text-base-content/30 mb-3 text-[10px] font-semibold tracking-widest uppercase">
              {{ !state.activeStepExecution.value && state.hasPinnedOutput.value ? 'Pinned Output' : 'Output Data' }}
            </h4>
            <div
              class="overflow-x-auto rounded-xl p-4 font-mono text-xs leading-relaxed whitespace-pre transition-all duration-200"
              :class="[
                state.hasPinnedOutput.value
                  ? ''
                  : 'bg-base-200/40 text-base-content/70',
              ]"
              :style="state.hasPinnedOutput.value ? {
                backgroundColor: oklchToHex(colorMap.pinned) + '0A',
                borderLeft: `3px solid ${oklchToHex(colorMap.pinned)}40`,
              } : {}"
            >{{ formatDataForDisplay(state.hasPinnedOutput.value ? state.pinnedOutput.value : state.activeStepExecution.value?.output_data) }}</div>
          </div>

          <!-- Error (inline in output tab) -->
          <div v-if="state.activeStepExecution.value?.error" class="mt-2">
            <h4 class="text-error/40 mb-2 text-[10px] font-semibold tracking-widest uppercase">
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
      <BoltIcon class="text-base-content/15 mb-3 size-12" />
      <p class="text-base-content/30 text-sm font-medium">No output yet</p>
      <p class="text-base-content/20 mt-1 text-xs">Run the workflow to see results</p>
    </div>
  </div>
</template>
