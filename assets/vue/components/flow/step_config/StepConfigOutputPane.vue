<script setup lang="ts">
import { inject } from 'vue';
import { BookmarkIcon, DocumentDuplicateIcon, BoltIcon } from '@heroicons/vue/24/outline';
import { formatDataForDisplay } from '@/lib/dataUtils';
import { colorMap, oklchToHex } from '@/lib/color';
import { StepConfigKey } from './useStepConfig';

const state = inject(StepConfigKey)!;
</script>

<template>
  <div class="custom-scrollbar mx-auto h-full max-w-4xl space-y-8 p-4">
    <div v-if="state.activeStepExecution.value || state.hasPinnedOutput.value" class="space-y-8 pb-20">
      <!-- Multi-Item Summary Bar (only with execution) -->
      <section
        v-if="state.activeStepExecution.value && state.isMultiItemStep.value && state.itemStats.value"
        class="bg-base-200/50 rounded-2xl p-4"
      >
        <div class="flex items-center justify-between">
          <div class="flex items-center gap-4">
            <span class="text-base-content/60 text-sm font-medium">
              {{ state.itemStats.value.itemsTotal }} items processed
            </span>
            <div class="flex items-center gap-2 text-xs">
              <span
                v-if="state.itemStats.value.completed > 0"
                class="text-success flex items-center gap-1"
              >
                <span class="bg-success inline-block size-2 rounded-full"></span>
                {{ state.itemStats.value.completed }} completed
              </span>
              <span v-if="state.itemStats.value.failed > 0" class="text-error flex items-center gap-1">
                <span class="bg-error inline-block size-2 rounded-full"></span>
                {{ state.itemStats.value.failed }} failed
              </span>
              <span v-if="state.itemStats.value.running > 0" class="text-info flex items-center gap-1">
                <span class="bg-info inline-block size-2 rounded-full"></span>
                {{ state.itemStats.value.running }} running
              </span>
            </div>
          </div>
          <button
            v-if="state.selectedItemIndex.value !== null"
            @click="state.selectedItemIndex.value = null"
            class="btn btn-xs btn-ghost"
          >
            Show All
          </button>
        </div>

        <!-- Item List -->
        <div class="mt-4 flex flex-wrap gap-2">
          <button
            v-for="se in state.stepExecutionsForStep.value"
            :key="se.id"
            @click="state.selectedItemIndex.value = se.item_index ?? 0"
            :class="[
              'btn btn-xs gap-1',
              state.selectedItemIndex.value === se.item_index ? 'btn-primary' : 'btn-ghost',
              se.status === 'failed' ? 'border-error/50' : '',
              se.status === 'completed' ? 'border-success/30' : '',
            ]"
          >
            <span
              :class="[
                'inline-block size-2 rounded-full',
                se.status === 'completed' ? 'bg-success' : '',
                se.status === 'failed' ? 'bg-error' : '',
                se.status === 'running' ? 'bg-info animate-pulse' : '',
                se.status === 'skipped' ? 'bg-base-content/30' : '',
              ]"
            ></span>
            #{{ (se.item_index ?? 0) + 1 }}
          </button>
        </div>
      </section>

      <!-- Item Header (when viewing specific item) -->
      <div
        v-if="state.activeStepExecution.value && state.isMultiItemStep.value && state.selectedItemIndex.value !== null"
        class="flex items-center gap-2 text-sm"
      >
        <span class="text-base-content/60">Viewing item</span>
        <span class="font-bold">#{{ state.selectedItemIndex.value + 1 }}</span>
        <span class="text-base-content/40">of {{ state.itemStats.value?.itemsTotal }}</span>
        <span
          :class="[
            'badge badge-sm',
            state.activeStepExecution.value.status === 'completed' ? 'badge-success' : '',
            state.activeStepExecution.value.status === 'failed' ? 'badge-error' : '',
            state.activeStepExecution.value.status === 'running' ? 'badge-info' : '',
          ]"
        >
          {{ state.activeStepExecution.value.status }}
        </span>
      </div>

      <!-- Input Data (only with execution) -->
      <section v-if="state.activeStepExecution.value">
        <div class="mb-3 flex items-center justify-between">
          <h4 class="text-base-content/40 text-xs font-bold tracking-widest uppercase">
            Input Data
          </h4>
          <button
            @click.stop="state.copyExpression('json')"
            class="btn btn-xs btn-ghost gap-1.5 text-[10px] capitalize opacity-60 hover:opacity-100"
          >
            <DocumentDuplicateIcon class="h-3 w-3" />
            Copy Expression
          </button>
        </div>
        <div
          class="bg-base-300/30 overflow-x-auto rounded-2xl p-4 font-mono text-xs whitespace-pre"
        >
          {{ formatDataForDisplay(state.activeStepExecution.value.input_data) }}
        </div>
      </section>

      <!-- Output Data (unified: shows pinned data when pinned, execution data otherwise) -->
      <section v-if="state.activeStepExecution.value || state.hasPinnedOutput.value">
        <div class="mb-3 flex items-center justify-between">
          <h4 class="text-base-content/40 text-xs font-bold tracking-widest uppercase">
            {{ !state.activeStepExecution.value && state.hasPinnedOutput.value ? 'Pinned Output' : 'Output Data' }}
          </h4>
          <div class="flex items-center gap-2">
            <button
              v-if="state.canEdit.value && !state.hasPinnedOutput.value && state.activeStepExecution.value"
              @click.stop="state.pinOutput()"
              class="btn btn-secondary btn-xs gap-1.5 text-[10px] capitalize shadow-sm transition-all shadow-secondary/20"
              :disabled="!state.canPinOutput.value"
              :title="
                state.canPinOutput.value
                  ? 'Pin this output for previews'
                  : 'Run the workflow to capture output before pinning'
              "
            >
              <BookmarkIcon class="h-3 w-3" />
              Pin Output
            </button>

            <button
              v-if="state.canEdit.value && state.hasPinnedOutput.value"
              @click.stop="state.unpinOutput()"
              class="btn btn-xs btn-ghost gap-1.5 text-[10px] capitalize text-error/60 hover:text-error hover:bg-error/10"
            >
              Unpin
            </button>

            <button
              v-if="state.activeStepExecution.value"
              @click.stop="state.copyExpression('steps', state.nodeId.value)"
              class="btn btn-xs btn-ghost gap-1.5 text-[10px] capitalize opacity-60 hover:opacity-100"
            >
              <DocumentDuplicateIcon class="h-3 w-3" />
              Copy Expression
            </button>

            <span v-if="state.hasPinnedOutput.value"
              class="badge badge-sm font-bold tracking-wider uppercase"
              :style="{
                backgroundColor: oklchToHex(colorMap.pinned),
                borderColor: oklchToHex(colorMap.pinned),
                color: 'white'
              }"
            >Pinned</span>
            <span
              v-else-if="state.activeStepExecution.value?.status === 'completed'"
              class="badge badge-success badge-sm"
              >Success</span
            >
          </div>
        </div>
        <div
          class="overflow-x-auto rounded-2xl border-2 p-4 font-mono text-xs whitespace-pre transition-all duration-300"
          :class="state.hasPinnedOutput.value ? 'shadow-lg' : 'bg-base-300/30 border-success/10'"
          :style="state.hasPinnedOutput.value ? {
            borderColor: oklchToHex(colorMap.pinned) + '66',
            backgroundColor: oklchToHex(colorMap.pinned) + '08',
            boxShadow: `0 10px 15px -3px ${oklchToHex(colorMap.pinned)}0D`
          } : {}"
        >
          {{ formatDataForDisplay(state.hasPinnedOutput.value ? state.pinnedOutput.value : state.activeStepExecution.value?.output_data) }}
        </div>
      </section>

      <!-- Error (only with execution) -->
      <section v-if="state.activeStepExecution.value?.error">
        <h4 class="text-error/60 mb-3 text-xs font-bold tracking-widest uppercase">
          Error
        </h4>
        <div
          class="bg-error/5 border-error/20 text-error rounded-2xl border p-4 font-mono text-xs"
        >
          {{ state.activeStepExecution.value.error }}
        </div>
      </section>
    </div>

    <div v-else class="flex h-full flex-col items-center justify-center opacity-40">
      <BoltIcon class="mb-4 h-16 w-16" />
      <p class="text-sm font-bold">No execution data available</p>
      <p class="text-xs">Run the workflow to see inputs and outputs</p>
    </div>
  </div>
</template>
